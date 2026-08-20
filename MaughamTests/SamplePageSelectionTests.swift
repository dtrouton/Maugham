import XCTest
@testable import Maugham

/// Task 2: `SamplePageSelection` — which pieces demonstrate the design.
final class SamplePageSelectionTests: XCTestCase {

    private func makeAST() -> ProjectAST {
        ProjectAST(sections: [
            .init(pieceID: "p1", title: "The Fog", mode: .prose, nodes: [
                .paragraph([.text("It rolled in.")]),
            ]),
            .init(pieceID: "p2", title: "Interlude", mode: .fountain, nodes: [
                .fountain(.lyric("La la la")),
            ]),
            .init(pieceID: "p3", title: "Kitchen Scene", mode: .fountain, nodes: [
                .fountain(.dualDialogue(
                    left: [.character("AARON"), .dialogue("Hi.")],
                    right: [.character("BETH"), .dialogue("Hi.")]
                )),
            ]),
        ])
    }

    func testFirstChapter_isAlwaysFirst() {
        let ast = makeAST()
        let census = ElementCensus.take(from: ast)
        let selection = SamplePageSelection.choose(census: census, ast: ast)
        XCTAssertEqual(selection.pieceIds.first, "p1")
    }

    func testEmptyProject_yieldsEmptySelection() {
        let ast = ProjectAST(sections: [])
        let census = ElementCensus.take(from: ast)
        let selection = SamplePageSelection.choose(census: census, ast: ast)
        XCTAssertTrue(selection.pieceIds.isEmpty)
        XCTAssertTrue(selection.demonstrates.isEmpty)
    }

    func testFullCoverage_everyCensusKindsFirstPieceIsSelected() {
        let ast = makeAST()
        let census = ElementCensus.take(from: ast)
        let selection = SamplePageSelection.choose(census: census, ast: ast)
        let requiredPieces = Set(census.firstPiece.values)
        XCTAssertTrue(requiredPieces.isSubset(of: Set(selection.pieceIds)))
    }

    func testKindOnlyInPieceN_pullsPieceNIn() {
        // .lyric appears only in p2; it must pull p2 into the selection.
        let ast = makeAST()
        let census = ElementCensus.take(from: ast)
        let selection = SamplePageSelection.choose(census: census, ast: ast)
        XCTAssertTrue(selection.pieceIds.contains("p2"))
        // .dualDialogue appears only in p3; it must pull p3 into the selection.
        XCTAssertTrue(selection.pieceIds.contains("p3"))
    }

    func testDeterminism_twoCallsProduceEqualResults() {
        let ast = makeAST()
        let census = ElementCensus.take(from: ast)
        let a = SamplePageSelection.choose(census: census, ast: ast)
        let b = SamplePageSelection.choose(census: census, ast: ast)
        XCTAssertEqual(a, b)
    }

    func testDeterminism_repeatedRunsAgreeAcrossManyKinds() {
        // Guards against Set-iteration-order nondeterminism: a fixture wide
        // enough that hash-order iteration over `Set<Kind>` would likely
        // scramble output across repeated runs if the implementation walked
        // the Set directly instead of a stable declared order.
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "One", mode: .prose, nodes: [.paragraph("a")]),
            .init(pieceID: "p2", title: "Two", mode: .prose, nodes: [
                .heading(level: 1, [.text("h")]),
                .blockquote([.sceneBreak]),
                .prose(.list(ordered: true, items: [[.text("i")]])),
                .prose(.verbatim(["code"])),
                .paragraph([
                    .strong([.text("b")]), .emphasis([.text("e")]),
                    .strikethrough([.text("s")]), .code("c"),
                    .wikiLink(target: "t", display: "d"), .lineBreak,
                ]),
            ]),
            .init(pieceID: "p3", title: "Three", mode: .fountain, nodes: [
                .fountain(.sceneHeading("INT. X - DAY")),
                .fountain(.action([.underline([.text("u")])])),
                .fountain(.character("A")),
                .fountain(.dialogue("d")),
                .fountain(.parenthetical("(p)")),
                .fountain(.transition("CUT TO:")),
                .fountain(.lyric("l")),
                .fountain(.centered("c")),
                .fountain(.pageBreak),
                .fountain(.titlePage([.init(key: "Title", value: "T")])),
                .fountain(.dualDialogue(left: [.character("A")], right: [.character("B")])),
            ]),
        ])
        let census = ElementCensus.take(from: ast)
        var results: [SamplePageSelection.Selection] = []
        for _ in 0..<20 {
            results.append(SamplePageSelection.choose(census: census, ast: ast))
        }
        XCTAssertTrue(results.allSatisfy { $0 == results[0] })
    }

    func testMaxPages_isASmallPositiveConstant() {
        let ast = makeAST()
        let census = ElementCensus.take(from: ast)
        let selection = SamplePageSelection.choose(census: census, ast: ast)
        XCTAssertGreaterThan(selection.maxPages, 0)
        XCTAssertLessThanOrEqual(selection.maxPages, 12)
        XCTAssertEqual(selection.maxPages, SamplePageSelection.maxPages)
    }

    func testDemonstrates_leadsWithTheChapterOpener() {
        let ast = makeAST()
        let census = ElementCensus.take(from: ast)
        let selection = SamplePageSelection.choose(census: census, ast: ast)
        XCTAssertEqual(selection.demonstrates.first, "chapter opener — \u{2018}The Fog\u{2019}")
    }

    func testDemonstrates_namesTheLyricKindAsVerse() {
        let ast = makeAST()
        let census = ElementCensus.take(from: ast)
        let selection = SamplePageSelection.choose(census: census, ast: ast)
        XCTAssertTrue(selection.demonstrates.contains("verse — \u{2018}Interlude\u{2019}"))
    }

    func testDemonstrates_hasOneLinePerSelectedPiece() {
        let ast = makeAST()
        let census = ElementCensus.take(from: ast)
        let selection = SamplePageSelection.choose(census: census, ast: ast)
        XCTAssertEqual(selection.demonstrates.count, selection.pieceIds.count)
    }

    func testASingleUncoveredPieceProject_selectsOnlyTheOpener() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "Solo", mode: .prose, nodes: [.paragraph("a")]),
        ])
        let census = ElementCensus.take(from: ast)
        let selection = SamplePageSelection.choose(census: census, ast: ast)
        XCTAssertEqual(selection.pieceIds, ["p1"])
        XCTAssertEqual(selection.demonstrates, ["chapter opener — \u{2018}Solo\u{2019}"])
    }

    func testAKindAlreadyInTheOpener_doesNotPullInAnotherPiece() {
        // p1 (the always-first opener) already contains .heading; a later
        // piece that ALSO has .heading must not be pulled in for that reason.
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "One", mode: .prose, nodes: [
                .heading(level: 1, [.text("h")]),
            ]),
            .init(pieceID: "p2", title: "Two", mode: .prose, nodes: [
                .heading(level: 1, [.text("h2")]),
            ]),
        ])
        let census = ElementCensus.take(from: ast)
        let selection = SamplePageSelection.choose(census: census, ast: ast)
        XCTAssertEqual(selection.pieceIds, ["p1"])
    }
}

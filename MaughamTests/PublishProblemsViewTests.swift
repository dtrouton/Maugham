import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The publish problems arm** (report foundations plan 2, Task 8): its rows
/// from literals, its reveal decision, the closure each row's verb calls, the
/// arm's precedence in Publish's centre, and — mounted — that every glyph
/// carries words and every row its verb. Nothing here presses a mounted
/// control and waits (tripwire 33): the verb is called directly.
@MainActor
final class PublishProblemsViewTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
    }

    private typealias Diagnostic = TectonicLogParser.Diagnostic

    private static let problems: [Diagnostic] = [
        Diagnostic(level: .error, file: nil, line: nil,
                   message: "@fig:storm is not a label in this book",
                   contextLines: [], pieceID: "ch-3", paragraphID: "k7m2"),
        Diagnostic(level: .warning, file: nil, line: nil,
                   message: "[^2] is never used", contextLines: [],
                   pieceID: "ch-1", paragraphID: nil),
        Diagnostic(level: .error, file: nil, line: nil,
                   message: "[@ghost] is not a source", contextLines: [],
                   pieceID: "ch-gone", paragraphID: "b3c4"),
    ]

    private static let titles = ["ch-1": "The Harbour", "ch-3": "Weather"]

    // MARK: - Rows from literals

    func test_eachRowNamesItsPieceByTitleWithItsMessageAndLevelInOrder() {
        let rows = PublishProblems.rows(Self.problems, titles: Self.titles)
        XCTAssertEqual(rows, [
            .init(id: 0, level: .error, pieceID: "ch-3", paragraphID: "k7m2",
                  title: "Weather", message: "@fig:storm is not a label in this book"),
            .init(id: 1, level: .warning, pieceID: "ch-1", paragraphID: nil,
                  title: "The Harbour", message: "[^2] is never used"),
            .init(id: 2, level: .error, pieceID: "ch-gone", paragraphID: "b3c4",
                  title: PublishProblems.untitledPiece,
                  message: "[@ghost] is not a source"),
        ])
        XCTAssertFalse(rows.contains { $0.title.hasPrefix("ch-") },
            "a row never shows a piece's id: the writer has never seen one")
    }

    func test_aDiagnosticWithNoPieceHasNoRow() {
        let tex = Diagnostic(level: .warning, file: "main.tex", line: 4,
                             message: "Overfull", contextLines: [])
        XCTAssertEqual(PublishProblems.rows([tex], titles: [:]), [])
    }

    func test_titlesAreReadOffTheStructureByDocumentId() {
        let structure = [
            StructureItem(id: "part-1", title: "Part One", type: .group, children: [
                StructureItem(id: "ch-1", title: "The Harbour", type: .document,
                              path: "manuscript/01.md"),
            ]),
            StructureItem(id: "ch-3", title: "Weather", type: .document,
                          path: "manuscript/03.md"),
        ]
        XCTAssertEqual(PublishProblems.titles(in: structure), Self.titles)
    }

    // MARK: - The reveal

    func test_aParagraphIsRevealedInTheSourceAndANilParagraphOpensThePiece() {
        XCTAssertEqual(
            PublishProblems.reveal(pieceID: "ch-3", paragraphID: "k7m2"),
            .paragraph(TranslationReveal(docId: "ch-3", language: nil,
                                         paragraphId: "k7m2")),
            "a source reveal: no language, so no translation review")
        XCTAssertEqual(PublishProblems.reveal(pieceID: "ch-1", paragraphID: nil),
                       .piece(.item("ch-1")))
    }

    func test_showInManuscriptHandsTheRowsOwnIdsToTheRevealClosure() {
        var received: [(String, String?)] = []
        let rows = PublishProblems.rows(Self.problems, titles: Self.titles)
        let view = PublishProblemsView(rows: rows, onClose: {},
                                       onReveal: { received.append(($0, $1)) })
        view.showInManuscript(rows[0])
        view.showInManuscript(rows[1])
        XCTAssertEqual(received.map(\.0), ["ch-3", "ch-1"])
        XCTAssertEqual(received.map(\.1), ["k7m2", nil])
    }

    func test_everyGlyphHasWords() {
        XCTAssertEqual(PublishProblems.glyph(.error).label, "Error")
        XCTAssertEqual(PublishProblems.glyph(.warning).label, "Warning")
        XCTAssertNotEqual(PublishProblems.glyph(.error).systemImage,
                          PublishProblems.glyph(.warning).systemImage)
    }

    // MARK: - The arm's place in the centre (R-S12)

    func test_problemsOutrankTheRoundAndTheGateAndDrawOverAChapter() {
        let round = PublishCentreModelTests.round()
        let proposal = PublishCentreModelTests.proposal()
        for subject: BinderSubject? in [nil, .project, .item("chapter-1")] {
            XCTAssertEqual(
                ProjectWindow.publishCentre(
                    persona: .publish, subject: subject,
                    structure: CentreRouteTests.structure,
                    preview: .nothingCompiled, proposal: proposal, round: round,
                    problems: Self.problems),
                .problems(Self.problems), "\(String(describing: subject))")
        }
        XCTAssertNil(ProjectWindow.publishCentre(
            persona: .author, subject: nil, structure: CentreRouteTests.structure,
            preview: .nothingCompiled, problems: Self.problems),
            "the persona guard applies to every arm")
        XCTAssertEqual(
            ProjectWindow.centreRoute(
                persona: .publish, subject: .item("chapter-1"), projectType: .novel,
                structure: CentreRouteTests.structure, showsPaletteWall: false,
                preview: .nothingCompiled, problems: Self.problems),
            .editor(altitude: false, cover: .publishProblems(Self.problems)))
    }

    func test_showProblemsClearsTheOtherShowsAndBackOrAPersonaChangeClearsIt() {
        let model = PublishCentreModel()
        model.show(round: PublishCentreModelTests.round())
        model.show(problems: Self.problems)
        XCTAssertEqual(model.selectedProblems, Self.problems)
        XCTAssertNil(model.selectedRound)
        XCTAssertNil(model.selectedProposal)

        model.show(proposal: PublishCentreModelTests.proposal())
        XCTAssertNil(model.selectedProblems, "another Show clears the list")

        model.show(problems: Self.problems)
        model.clearProblems()
        XCTAssertNil(model.selectedProblems, "Back clears it")

        model.show(problems: Self.problems)
        model.clearDecisions()
        XCTAssertNil(model.selectedProblems, "a persona change clears it")
    }

    // MARK: - Mounted: words, not colour alone

    func test_theMountedListDrawsEachGlyphsWordsTitleAndVerb() async throws {
        let rows = PublishProblems.rows(Self.problems, titles: Self.titles)
        let window = TestWindow.mount(
            AnyView(PublishProblemsView(rows: rows, onClose: {}, onReveal: { _, _ in })
                .frame(maxWidth: .infinity, maxHeight: .infinity)),
            size: CGSize(width: 520, height: 500))
        windows.append(window)
        pump(0.1)
        _ = await pumpUntil(deadline: 3) {
            ((try? self.axTexts(in: window)) ?? []).contains("Weather")
        }

        let texts = try axTexts(in: window)
        for expected in ["Weather", "The Harbour", PublishProblems.untitledPiece,
                         "[^2] is never used"] {
            XCTAssertTrue(texts.contains(expected), "missing \(expected): \(texts.sorted())")
        }
        XCTAssertEqual(texts.filter { $0 == PublishProblems.errorLabel }.count, 2,
            "each error row's glyph is published with its word: \(texts.sorted())")
        XCTAssertEqual(texts.filter { $0 == PublishProblems.warningLabel }.count, 1,
            "\(texts.sorted())")

        let buttons = try axButtonLabels(in: window)
        XCTAssertTrue(buttons.contains(
            PublishProblems.showInManuscriptAccessibilityLabel(title: "Weather")),
            "\(buttons.sorted())")
        XCTAssertTrue(buttons.contains(PublishProblems.closeAccessibilityLabel),
            "\(buttons.sorted())")
    }
}

import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **An edition's Brief** (shell plan 3 Task 5): its edition brief (essay,
/// rulings, the glossary they hold) through the desk's own `StatementPane`,
/// the cast read by name, and Visual Language pulling up; the source edition
/// is the book itself. Pure decisions, a census and mounted measurements.
@MainActor
final class BriefEditionTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var fixtures: [StatementMountFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures { fixture.tearDown() }
        fixtures.removeAll()
        try await super.tearDown()
    }

    private func fixture(_ name: String) async throws -> StatementMountFixture {
        let made = try await StatementMountFixture.novel(named: name)
        fixtures.append(made)
        return made
    }

    private func pane(_ f: StatementMountFixture, language: String) -> AnyView {
        AnyView(BriefPane(store: f.store, documentStore: f.documentStore,
                          scope: .edition(language: language),
                          diagnostics: nil, bible: nil, world: nil, centreItem: nil,
                          onOpenInCentre: { _ in }, onPullUp: { _ in },
                          onShowStrain: { _, _ in }, onOpenBrief: { _ in }))
    }

    func test_anEditionsBriefIsItsBriefGlossaryCastAndVisualLanguage() async throws {
        XCTAssertEqual(BriefEditionView.parts(isSource: false), [.brief, .cast, .visualLanguage])
        XCTAssertNil(BriefEditionView.briefPrompt(hasBrief: true))
        XCTAssertEqual(BriefEditionView.briefPrompt(hasBrief: false), BriefEditionView.noBriefPrompt,
                       "an edition with no brief: a prompt over the editor that writes one")

        let f = try await fixture("BriefEdition")
        let statement = try await f.store.createStatement(kind: .editionBrief("es"), scope: .project)
        let glossary = Ruling(id: "", text: "«harbour» → «puerto» (never muelle)",
                              ruledOn: Date(timeIntervalSince1970: 1_700_000_000), provenance: "test")
        let text = RulingsSection.render(essay: "Spanish that reads like the Río de la Plata.",
                                         rulings: [glossary])
        try await f.store.mutateStatementText(of: statement, session: "brief-edition-test") { _ in text }

        let cast = BriefEditionView.cast(language: "es", in: f.store.manifest)
        XCTAssertEqual(cast.first?.role, "Translator")
        XCTAssertEqual(cast.first?.name, EditionStatus.translatorName(for: "es", in: f.store.manifest),
                       "the cast is read by name, without minting")

        let window = f.hostView(AnyView(pane(f, language: "es").frame(height: 800)))
        await pumpUntil(deadline: 5) {
            f.shows(BriefBookView.visualLanguageTitle, in: window) && !f.allTextViews(in: window).isEmpty
        }
        let texts = try f.allStaticTexts(in: window)
        func position(_ needle: String) -> Int? { texts.firstIndex { $0.contains(needle) } }
        let header = StatementPane.headerCaption(kind: .editionBrief("es"), scope: .project, structure: [])
        let order = [header, RulingsStratum.glossaryHeading, BriefEditionView.castHeading, "Translator",
                     BriefBookView.visualLanguageTitle]
        let positions = order.map(position)
        XCTAssertFalse(positions.contains(nil),
                       "missing: \(zip(order, positions).filter { $1 == nil }.map(\.0)) in \(texts)")
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted(),
                       "the brief (its glossary inside), the cast, then Visual Language: \(texts)")
        XCTAssertEqual(f.allTextViews(in: window).count, 1, "the brief's own editor")
        XCTAssertTrue(f.store.openStatementDocument(id: statement.id) != nil,
                      "bound to the edition brief")
        XCTAssertFalse(f.shows(BriefEditionView.noBriefPrompt, in: window), "a written brief has no prompt")
    }

    func test_theSourceEditionHasNoBrief() async throws {
        XCTAssertEqual(BriefEditionView.parts(isSource: true), [.sourceLine, .visualLanguage])
        XCTAssertTrue(BriefEditionView.isSource("EN", source: "en"), "tags compare as the desk compares them")
        XCTAssertFalse(BriefEditionView.isSource("es", source: "en"))

        let f = try await fixture("BriefSourceEdition")
        let source = BriefEditionView.sourceLanguage(store: f.store)
        let window = f.hostView(pane(f, language: source))
        await pumpUntil(deadline: 5) { f.shows(BriefEditionView.sourceLine, in: window) }
        await waitOut(0.3)
        XCTAssertTrue(f.shows(BriefEditionView.sourceLine, in: window))
        XCTAssertTrue(f.shows(BriefBookView.visualLanguageTitle, in: window))
        XCTAssertTrue(f.allTextViews(in: window).isEmpty, "no brief, so no editor")
        XCTAssertFalse(f.shows(BriefEditionView.castHeading, in: window))
        XCTAssertNil(f.store.statement(kind: .editionBrief(source), scope: .project),
                     "and nothing was minted for it")
    }

    /// The cast is read here and changed on the desk: no cast sheet, no
    /// minting role lookup, no manifest write in this file.
    func test_theCastIsReadNotWritten() throws {
        let code = SourceScan.codeLines(of: try GoingForTests.source("Maugham/Views/Brief/BriefEditionView.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(BriefEditionTests.castWrites(in: code).isEmpty,
                      "the edition's Brief writes the cast: \(BriefEditionTests.castWrites(in: code))")
        XCTAssertTrue(code.contains("EditionStatus.translatorName("), "premise: it reads the cast")

        let planted = """
        let role = try await store.translatorRole(for: language)
        DepartmentCastSheet(store: store)
        try await store.renameProductionRole(id: role.id, to: name)
        """
        XCTAssertEqual(BriefEditionTests.castWrites(in: planted).count, 3, "the census sees a write")
    }

    static func castWrites(in code: String) -> [String] {
        ["DepartmentCastSheet(", "translatorRole(", "readerRole(", "collatorRole(",
         "renameProductionRole(", "commitProductionRoles(", "updateInspector(", "manifest ="]
            .filter { code.contains($0) }
    }
}

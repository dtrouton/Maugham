import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **An edition's Brief** (shell plan 3 Task 5; the cast's home since shell
/// p4 Task 7): its edition brief (essay, rulings, the glossary they hold)
/// through `StatementPane`, the cast by name with the door that changes it,
/// and Visual Language pulling up; the source edition is the book itself, its
/// designer, and any brief proposed for an edition the book does not have
/// yet. Pure decisions, censuses, store-level acts and mounted reads.
@MainActor
final class BriefEditionTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var fixtures: [StatementMountFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures { await fixture.closeAndTearDown() }
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
                          onShowStrain: { _ in }, onOpenBrief: { _ in }))
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
        XCTAssertEqual(BriefEditionView.parts(isSource: true),
                       [.sourceLine, .designer, .proposedEditions, .visualLanguage])
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
        XCTAssertTrue(f.shows(BriefEditionView.designerHeading.uppercased(), in: window)
                      || f.shows(BriefEditionView.designerHeading, in: window),
                      "the Source names who designs the book")
        XCTAssertTrue(f.shows(f.store.designerRole().effectiveName, in: window))
        XCTAssertNil(f.store.statement(kind: .editionBrief(source), scope: .project),
                     "and nothing was minted for it")
    }

    /// **The translator is renamed from the edition's Brief** (shell p4 Task
    /// 7): the Cast heading carries its door, the sheet starts from the cast
    /// as it reads, and Confirm names the whole cast in the store. Read and
    /// called, never pressed (tripwire 33).
    func test_theTranslatorIsRenamedFromTheEditionsBrief() async throws {
        let f = try await fixture("BriefEditionRename")
        await f.documentStore.postureSettled()
        XCTAssertTrue(EditionCastVerbs.mayCast(language: "es", store: f.store, documentStore: f.documentStore),
                      "premise: the book's author may change the cast")
        let window = f.hostView(AnyView(pane(f, language: "es").frame(height: 800)))
        let door = EditionCastVerbs.castDoorLabel(language: "es")
        await pumpUntil(deadline: 5) { ((try? self.doors(labelled: door, in: window))?.count ?? 0) == 1 }
        XCTAssertEqual(try doors(labelled: door, in: window).count, 1,
                       "the Cast heading carries one door")

        let prompt = EditionCastVerbs.renamePrompt(language: "es", in: f.store.manifest)
        XCTAssertEqual(prompt.ask, .rename(subject: .edition(language: "es"),
                                           currentName: EditionStatus.translatorName(
                                               for: "es", in: f.store.manifest) ?? ""))
        XCTAssertNotNil(prompt.currentReader, "the sheet starts from the whole cast")
        XCTAssertTrue(f.store.manifest.productionRoles.isEmpty, "asking mints nothing")

        let failure = await EditionCastVerbs.confirmRename(
            EditionCastAnswer(language: nil, name: "Borges", reader: "Pizarnik", collator: nil),
            prompt: prompt, store: f.store, documentStore: f.documentStore)
        XCTAssertNil(failure)
        XCTAssertEqual(EditionStatus.translatorName(for: "es", in: f.store.manifest), "Borges")
        XCTAssertEqual(EditionStatus.readerName(for: "es", in: f.store.manifest), "Pizarnik")
        await pumpUntil(deadline: 5) { f.shows("Borges", in: window) }
        XCTAssertTrue(f.shows("Borges", in: window), "the Brief reads the cast it was given")

        // The designer, from the Source's Brief.
        let designer = await EditionCastVerbs.confirmRename(
            EditionCastAnswer(language: nil, name: "Bringhurst"),
            prompt: EditionCastVerbs.designerPrompt(store: f.store),
            store: f.store, documentStore: f.documentStore)
        XCTAssertNil(designer)
        XCTAssertEqual(f.store.designerRole().effectiveName, "Bringhurst")
    }

    /// **A proposed edition brief shows on its edition's Brief**, the gate
    /// over the brief's editor with Adopt and Discard — as the book's
    /// proposals do (`StatementPane`'s gate).
    func test_aProposedEditionBriefShowsOnItsEditionsBrief() async throws {
        let f = try await fixture("BriefEditionProposal")
        _ = try StatementProposalStore(projectURL: f.projectURL).stage(.init(
            kind: .editionBrief("es"), markdown: "Rioplatense, voseo throughout.",
            rationale: "the narrator is porteño", proposedAt: Date(), author: "Claude"))
        let window = f.hostView(AnyView(pane(f, language: "es").frame(height: 800)))
        await pumpUntil(deadline: 5) { f.shows("the narrator is porteño", in: window) }
        XCTAssertTrue(f.shows("the narrator is porteño", in: window),
                      "the proposal's rationale is on the edition's Brief")
        XCTAssertEqual(try axButtons(
            labelled: StatementProposalCopy.adoptAccessibilityLabel(.editionBrief("es")),
            in: window).count, 1, "with its Adopt")
    }

    /// **A proposal for a language with no edition shows on the Source
    /// edition's Brief**, with the way to add that edition and to discard it;
    /// a proposal for an edition the book has does not.
    func test_aProposalWithNoEditionShowsOnTheSourceBrief() async throws {
        let f = try await fixture("BriefSourceProposal")
        await f.documentStore.postureSettled()
        _ = try await f.store.translatorRole(for: "es")
        for language in ["it", "es"] {
            _ = try StatementProposalStore(projectURL: f.projectURL).stage(.init(
                kind: .editionBrief(language), markdown: "x", rationale: nil,
                proposedAt: Date(), author: "Claude"))
        }
        let source = BriefEditionView.sourceLanguage(store: f.store)
        let window = f.hostView(AnyView(pane(f, language: source).frame(height: 800)))
        let italian = EditionCastVerbs.proposedWithoutAnEditionLine(language: "it")
        let add = EditionCastVerbs.addProposedTitle(language: "it")
        await pumpUntil(deadline: 5) {
            f.shows(italian, in: window)
                && ((try? self.axButtonLabels(in: window))?.contains(add) ?? false)
        }
        XCTAssertTrue(f.shows(italian, in: window))
        XCTAssertFalse(f.shows(EditionCastVerbs.proposedWithoutAnEditionLine(language: "es"), in: window),
                       "Spanish has an edition: its proposal is on its own Brief")
        let labels = try axButtonLabels(in: window)
        XCTAssertEqual(labels.filter { $0 == EditionCastVerbs.addProposedTitle(language: "it") }.count, 1,
                       "\(labels)")
        XCTAssertEqual(labels.filter { $0 == EditionCastVerbs.discardProposalLabel(language: "it") }.count, 1)

        // Discard, called: the slot empties and the Spanish one stands.
        let refusal = await EditionCastVerbs.discardProposal(
            language: "it", store: f.store, documentStore: f.documentStore)
        XCTAssertNil(refusal)
        let pending = StatementProposalStore(projectURL: f.projectURL).pendingAll().map(\.kind)
        XCTAssertEqual(pending, [.editionBrief("es")])
    }

    /// The cast is read here and changed through `EditionCastVerbs` alone:
    /// no minting role lookup and no manifest write in this file.
    func test_theCastIsReadNotWritten() throws {
        let code = SourceScan.codeLines(of: try GoingForTests.source("Maugham/Views/Brief/BriefEditionView.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(BriefEditionTests.castWrites(in: code).isEmpty,
                      "the edition's Brief writes the cast: \(BriefEditionTests.castWrites(in: code))")
        XCTAssertTrue(code.contains("EditionStatus.translatorName("), "premise: it reads the cast")
        XCTAssertTrue(code.contains("EditionCastVerbs.confirmRename("), "premise: it changes it through the verbs")

        let planted = """
        let role = try await store.translatorRole(for: language)
        try await store.renameProductionRole(id: role.id, to: name)
        """
        XCTAssertEqual(BriefEditionTests.castWrites(in: planted).count, 2, "the census sees a write")
    }

    /// A Brief's doors are links (`.buttonStyle(.link)`): every button or
    /// link carrying `label`.
    private func doors(labelled label: String, in window: NSWindow) throws -> [AnyObject] {
        try axElements(in: window)
            .filter { ["AXButton", "AXLink"].contains(axAttribute($0, "accessibilityRole") as? String ?? "") }
            .filter { (axAttribute($0, "accessibilityLabel") as? String) == label }
    }

    static func castWrites(in code: String) -> [String] {
        ["translatorRole(", "readerRole(", "collatorRole(",
         "renameProductionRole(", "commitProductionRoles(", "updateInspector(", "manifest ="]
            .filter { code.contains($0) }
    }
}

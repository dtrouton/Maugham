import XCTest
@testable import Maugham
import MaughamCore

@MainActor
final class StatementProposalBannerTests: XCTestCase {

    private func proposal(_ kind: ProposableStatement, _ markdown: String,
                          rationale: String? = nil, at: Date = Date()) -> StatementProposalStore.Proposal {
        .init(kind: kind, markdown: markdown, rationale: rationale, proposedAt: at, author: "Claude")
    }

    func test_theDiffIsLineLevelAndKeepsOrder() {
        let lines = StatementProposalDiff.lines(current: "a\nb\nc", proposed: "a\nB\nc\nd")
        XCTAssertEqual(lines.map(\.kind), [.same, .removed, .added, .same, .added])
        XCTAssertEqual(lines.map(\.text), ["a", "b", "B", "c", "d"])
    }

    func test_anIdenticalTextIsAllSameAndAnEmptyCurrentIsAllAdded() {
        XCTAssertTrue(StatementProposalDiff.lines(current: "x\ny", proposed: "x\ny").allSatisfy { $0.kind == .same })
        XCTAssertTrue(StatementProposalDiff.lines(current: "", proposed: "x\ny").allSatisfy { $0.kind == .added })
    }

    /// The rulings tail is not on the table: Adopt never touches it, so the
    /// diff must not show it as removed.
    func test_aBriefIsComparedEssayToEssayAndVisualLanguageWhole() {
        let p = proposal(.editionBrief("es"), "New.\n\n## Rulings\n\n- «a» → «b»\n")
        let compared = StatementProposalDiff.compared(current: "Old.\n\n## Rulings\n\n- kept — ruled 1 Sep 2026, by hand\n", proposal: p)
        XCTAssertEqual(compared.current, "Old.")
        XCTAssertEqual(compared.proposed, "New.")
        let look = proposal(.visualLanguage, "New look.\n\n## Rulings\n\n- prose here\n")
        let whole = StatementProposalDiff.compared(current: "Old look.", proposal: look)
        XCTAssertEqual(whole.proposed, "New look.\n\n## Rulings\n\n- prose here\n")
    }

    func test_theModelCarriesEverySentenceTheBannerDraws() {
        let now = Date()
        let p = proposal(.editionBrief("es"), "New.\n\n## Rulings\n\n- «a» → «b»\n- «c» → «d»\n",
                         rationale: "the chapter is intimate", at: now.addingTimeInterval(-120))
        let model = StatementProposalBanner.model(proposal: p, current: nil, statementExists: false, now: now)
        XCTAssertEqual(model.title, StatementProposalCopy.bannerTitle(p))
        XCTAssertEqual(model.when, "2 minutes ago")
        XCTAssertEqual(model.rationale, "the chapter is intimate")
        XCTAssertEqual(model.glossaryLine, StatementProposalCopy.glossaryLine(count: 2))
        XCTAssertEqual(model.createsLine, StatementProposalCopy.firstAdoptCreatesLine(.editionBrief("es")))
        XCTAssertTrue(model.diff.allSatisfy { $0.kind == .added })

        let existing = StatementProposalBanner.model(proposal: p, current: "Old.", statementExists: true, now: now)
        XCTAssertNil(existing.createsLine)
        XCTAssertEqual(existing.diff.map(\.kind), [.removed, .added])
    }

    func test_aVisualLanguageProposalNeverAnnouncesGlossary() {
        let p = proposal(.visualLanguage, "Serif.")
        let model = StatementProposalBanner.model(proposal: p, current: "Sans.", statementExists: true, now: Date())
        XCTAssertNil(model.glossaryLine)
    }
}

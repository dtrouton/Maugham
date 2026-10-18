import XCTest
@testable import Maugham

/// **The Publish centre's selection, as one model** (foundations plan 4 Task
/// 2). `ProjectWindow` used to hold four `@State` values for this column and
/// enforce, at two closure sites, that a design proposal and a translation
/// round clear each other; the rules now live here, pinned without a window.
///
/// The mounted halves — that a persona change reaches `clearDecisions`, that a
/// compile reaches `publishSelection(after:)`, that an announcement reaches the
/// re-read — stay in `PublishPreviewCentreTests`, which drives the production
/// modifier over this same model.
@MainActor
final class PublishCentreModelTests: XCTestCase {

    // MARK: - One centre, one selection

    func test_showingAProposalClearsTheRound() {
        let model = PublishCentreModel()
        model.show(round: Self.round())
        model.show(proposal: Self.proposal())

        XCTAssertEqual(model.selectedProposal?.id, Self.proposal().id)
        XCTAssertNil(model.selectedRound,
                     "the gate and the report are two readings of one column — "
                     + "leaving both set makes which one draws a question about "
                     + "write order")
    }

    func test_showingARoundClearsTheProposal() {
        let model = PublishCentreModel()
        model.show(proposal: Self.proposal())
        model.show(round: Self.round())

        XCTAssertEqual(model.selectedRound, Self.round())
        XCTAssertNil(model.selectedProposal)
    }

    func test_eachDismissClearsOnlyItsOwnSelection() {
        let model = PublishCentreModel()
        model.selectedPublicationID = "pub-older"
        model.show(proposal: Self.proposal())
        model.clearProposal()
        XCTAssertNil(model.selectedProposal)

        model.show(round: Self.round())
        model.clearRound()
        XCTAssertNil(model.selectedRound)
        XCTAssertEqual(model.selectedPublicationID, "pub-older",
                       "Back from a gate or a report is not news about the book")
    }

    /// A persona change lets both decisions go and keeps the reading's pick —
    /// the asymmetry `PublishPreviewModifier`'s doc argues.
    func test_clearingTheDecisionsKeepsTheBooksPick() {
        let model = PublishCentreModel()
        model.selectedPublicationID = "pub-older"
        model.show(proposal: Self.proposal())
        model.clearDecisions()
        XCTAssertNil(model.selectedProposal)

        model.show(round: Self.round())
        model.clearDecisions()
        XCTAssertNil(model.selectedRound)
        XCTAssertEqual(model.selectedPublicationID, "pub-older")
    }

    // MARK: - A new compile resets the picker (moved from PublishPreviewModifier.refresh)

    /// `test_aNewCompileTakesTheWritersPickBackToTheNewest`, windowless: a
    /// resolution whose NEWEST book changed takes the writer's pick away.
    func test_aNewNewestBookTakesTheWritersPickAway() {
        let model = PublishCentreModel()
        model.publishSelection(after: .ready(newestFirst: [Self.v11, Self.v10]))
        model.selectedPublicationID = Self.v10.publicationID

        let next = PublishPreviewResolution.ready(newestFirst: [Self.v12, Self.v11, Self.v10])
        model.publishSelection(after: next)

        XCTAssertNil(model.selectedPublicationID,
                     "a compile that finishes puts the writer on the book they "
                     + "just made")
        XCTAssertEqual(model.preview, next)
    }

    /// `test_arrivingInPublishAgainKeepsTheWritersPick`, windowless: a refresh
    /// whose newest book is the same one is not news.
    func test_aRefreshWithTheSameNewestBookKeepsThePick() {
        let model = PublishCentreModel()
        model.publishSelection(after: .ready(newestFirst: [Self.v11, Self.v10]))
        model.selectedPublicationID = Self.v10.publicationID

        model.publishSelection(after: .ready(newestFirst: [Self.v11, Self.v10]))

        XCTAssertEqual(model.selectedPublicationID, Self.v10.publicationID)
    }

    /// Keyed on the newest book's identity, so the newest DISAPPEARING (the file
    /// deleted in the Finder) is a change too — exactly as the old inline
    /// comparison of two optionals answered.
    func test_theNewestBookVanishingIsAChangeToo() {
        let model = PublishCentreModel()
        model.publishSelection(after: .ready(newestFirst: [Self.v11, Self.v10]))
        model.selectedPublicationID = Self.v10.publicationID

        model.publishSelection(after: .nothingCompiled)

        XCTAssertNil(model.selectedPublicationID)
        XCTAssertEqual(model.preview, .nothingCompiled)
    }

    /// …and two resolutions with no newest book at all (never compiled, an
    /// unreadable catalog) compare equal, so neither moves the pick.
    func test_twoResolutionsWithNoBookLeaveThePickAlone() {
        let model = PublishCentreModel()
        model.selectedPublicationID = "pub-whatever"

        model.publishSelection(after: .unreadableCatalog(reason: "unreadable"))

        XCTAssertEqual(model.selectedPublicationID, "pub-whatever")
        XCTAssertEqual(model.preview, .unreadableCatalog(reason: "unreadable"))
    }

    // MARK: - A verb's answer lands only on the selection still on screen

    func test_aProposalVerbsAnswerLandsOnlyOnTheProposalOnScreen() {
        var promoted = Self.proposal()
        promoted.status = .approved

        let model = PublishCentreModel()
        model.show(proposal: Self.proposal())
        model.adoptVerbAnswer(promoted)
        XCTAssertEqual(model.selectedProposal?.status, .approved)

        model.show(proposal: Self.proposal(id: "prop-somewhere-else"))
        model.adoptVerbAnswer(promoted)
        XCTAssertEqual(model.selectedProposal?.id, "prop-somewhere-else",
                       "the writer moved on; the answer must not pull them back")

        model.clearProposal()
        model.adoptVerbAnswer(promoted)
        XCTAssertNil(model.selectedProposal, "…nor reopen a gate they closed")
    }

    /// The adopted answer is still the gate's: it must never clear a round the
    /// writer opened since.
    func test_aProposalVerbsLateAnswerLeavesTheRoundOnScreen() {
        let model = PublishCentreModel()
        model.show(proposal: Self.proposal())
        model.show(round: Self.round())
        model.adoptVerbAnswer(Self.proposal())

        XCTAssertNil(model.selectedProposal)
        XCTAssertEqual(model.selectedRound, Self.round())
    }

    func test_aRoundVerbsAnswerLandsOnlyOnTheRoundOnScreen() {
        var updated = Self.round()
        updated.endedAt = Date(timeIntervalSince1970: 3_000)
        let other = TranslationRound(number: 4, language: "es", docId: "doc-1",
                                     startedAt: Date(timeIntervalSince1970: 1_000))

        let model = PublishCentreModel()
        model.show(round: Self.round())
        model.adoptVerbAnswer(updated)
        XCTAssertEqual(model.selectedRound, updated)

        model.show(round: other)
        model.adoptVerbAnswer(updated)
        XCTAssertEqual(model.selectedRound, other)

        model.clearRound()
        model.adoptVerbAnswer(updated)
        XCTAssertNil(model.selectedRound)
    }

    // MARK: - The proposal's re-read

    func test_theRereadAsksOnlyWhenAGateIsOpen() {
        let model = PublishCentreModel()
        var asked = false
        model.rereadProposal { _ in asked = true; return nil }
        XCTAssertFalse(asked, "no gate open, nothing to re-read")
        XCTAssertNil(model.selectedProposal)
    }

    func test_theRereadReplacesByIdOrClearsWhenGone() {
        let model = PublishCentreModel()
        model.show(proposal: Self.proposal())
        var superseded = Self.proposal()
        superseded.status = .superseded

        var askedFor: String?
        model.rereadProposal { id in askedFor = id; return superseded }
        XCTAssertEqual(askedFor, Self.proposal().id)
        XCTAssertEqual(model.selectedProposal?.status, .superseded)

        model.rereadProposal { _ in nil }
        XCTAssertNil(model.selectedProposal,
                     "an unreadable proposal clears the gate rather than leaving "
                     + "a ghost")
    }

    // MARK: - Fixtures

    static let v10 = PublishPreviewCentreTests.publication(
        version: "1.0", outputPath: "Exports/a.pdf",
        compiledAt: Date(timeIntervalSince1970: 1_770_000_000))
    static let v11 = PublishPreviewCentreTests.publication(
        version: "1.1", outputPath: "Exports/b.pdf",
        compiledAt: Date(timeIntervalSince1970: 1_770_000_600))
    static let v12 = PublishPreviewCentreTests.publication(
        version: "1.2", outputPath: "Exports/c.pdf",
        compiledAt: Date(timeIntervalSince1970: 1_770_001_200))

    static func proposal(id: String = "prop-preview") -> DesignProposalStore.Proposal {
        DesignProposalStore.Proposal(
            id: id, designerName: "Tschichold", round: 1, language: nil,
            created: Date(timeIntervalSince1970: 1_770_000_000), status: .pending,
            specMarkdown: "# a design", filePaths: ["template.tex"],
            sampleResult: nil, revertNote: nil)
    }

    static func round() -> TranslationRound {
        TranslationRound(number: 3, language: "es", docId: "doc-1",
                         startedAt: Date(timeIntervalSince1970: 1_000))
    }
}

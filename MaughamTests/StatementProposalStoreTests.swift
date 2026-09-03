import XCTest
@testable import Maugham
import MaughamCore

/// The derived slot a Claude Desktop draft waits in until the writer adopts or
/// discards it (translation pipeline spec §10). One pending proposal per key;
/// craft intent is UNREPRESENTABLE here rather than refused at runtime.
@MainActor
final class StatementProposalStoreTests: XCTestCase {
    private var temp: TempDirectory!
    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private var store: StatementProposalStore { StatementProposalStore(projectURL: temp.url) }

    // MARK: - The kind

    func test_theKindHasExactlyTwoCasesAndCraftIntentIsUnrepresentable() {
        XCTAssertNil(ProposableStatement(kind: .intent))
        XCTAssertNil(ProposableStatement(kind: .unknown("later")))
        XCTAssertEqual(ProposableStatement(kind: .visualLanguage), .visualLanguage)
        XCTAssertEqual(ProposableStatement(kind: .editionBrief("es")), .editionBrief("es"))
        XCTAssertEqual(ProposableStatement.visualLanguage.statementKind, .visualLanguage)
        XCTAssertEqual(ProposableStatement.editionBrief("es").statementKind, .editionBrief("es"))
    }

    func test_theKeyIsAFilenameNotARawValue() {
        XCTAssertEqual(ProposableStatement.visualLanguage.key, "visual-language")
        XCTAssertEqual(ProposableStatement.editionBrief("pt-br").key, "edition-brief-pt-br")
        XCTAssertEqual(ProposableStatement.editionBrief("ES").key, "edition-brief-es",
                       "the tag is lowercased so a badly-cased proposal lands in the same slot")
        XCTAssertFalse(ProposableStatement.editionBrief("es").key.contains(":"),
                       "a colon in a filename is hostile on every filesystem the writer syncs to")
    }

    // MARK: - Validation

    func test_aProposalWithOnlyGlossaryLinesUnderRulingsIsAccepted() throws {
        let markdown = """
        Register: informal, warm.

        ## Rulings

        - «October» → «Octubre» (the month, never a name)
        - «Kelly» → «Kelly»
        """
        try StatementProposalStore.validate(kind: .editionBrief("es"), markdown: markdown)
        let lines = try StatementProposalStore.glossaryLines(in: markdown)
        XCTAssertEqual(lines.map(\.term), ["October", "Kelly"])
        XCTAssertEqual(lines.map(\.rendering), ["Octubre", "Kelly"])
        XCTAssertEqual(lines.map(\.note), ["the month, never a name", nil])
    }

    func test_aRulingsLineThatIsNotGlossaryShapedIsRefusedByName() {
        let markdown = "Prose.\n\n## Rulings\n\n- «October» → «Octubre»\n- ¶k7mq: keep the three ands\n"
        XCTAssertThrowsError(try StatementProposalStore.validate(kind: .editionBrief("es"), markdown: markdown)) {
            XCTAssertEqual($0 as? StatementProposalStore.ProposalRefusal,
                           .rulingsNotGlossary(line: "¶k7mq: keep the three ands"))
        }
    }

    /// The P1 carry: an empty term is refused, not written.
    func test_anEmptyGlossaryTermIsRefused() {
        let markdown = "Prose.\n\n## Rulings\n\n- « » → «Octubre»\n"
        XCTAssertThrowsError(try StatementProposalStore.validate(kind: .editionBrief("es"), markdown: markdown)) {
            XCTAssertEqual($0 as? StatementProposalStore.ProposalRefusal,
                           .emptyGlossaryTerm(line: "« » → «Octubre»"))
        }
    }

    func test_aVisualLanguageProposalMayNotCarryRulings() {
        let markdown = "Serif, generous leading.\n\n## Rulings\n\n- «a» → «b»\n"
        XCTAssertThrowsError(try StatementProposalStore.validate(kind: .visualLanguage, markdown: markdown)) {
            XCTAssertEqual($0 as? StatementProposalStore.ProposalRefusal, .visualLanguageCarriesRulings)
        }
        XCTAssertNoThrow(try StatementProposalStore.validate(kind: .visualLanguage, markdown: "Serif."))
    }

    func test_emptyMarkdownAndABadTagAreRefused() {
        XCTAssertThrowsError(try StatementProposalStore.validate(kind: .visualLanguage, markdown: "  \n")) {
            XCTAssertEqual($0 as? StatementProposalStore.ProposalRefusal, .emptyMarkdown)
        }
        XCTAssertThrowsError(try StatementProposalStore.validate(kind: .editionBrief("Español"), markdown: "x")) {
            XCTAssertEqual($0 as? StatementProposalStore.ProposalRefusal, .invalidLanguageTag("Español"))
        }
    }

    // MARK: - The slot

    func test_stageWritesOneJSONFileUnderMaughamStatementsProposals() throws {
        let proposal = try store.stage(.init(kind: .editionBrief("es"), markdown: "Register: tú.",
                                             rationale: "the sample chapter is intimate",
                                             proposedAt: Date(), author: "Claude"))
        let file = StatementProposalStore.fileURL(key: "edition-brief-es", in: temp.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(file.path.contains("/.maugham/statements/proposals/"))
        XCTAssertEqual(store.pending(for: .editionBrief("es")), proposal)
        XCTAssertNil(store.pending(for: .visualLanguage))
    }

    func test_aNewProposalSupersedesThePendingOneForTheSameKey() throws {
        _ = try store.stage(.init(kind: .visualLanguage, markdown: "first", rationale: nil,
                                  proposedAt: Date(timeIntervalSinceNow: -60), author: "Claude"))
        let second = try store.stage(.init(kind: .visualLanguage, markdown: "second", rationale: nil,
                                           proposedAt: Date(), author: "Claude"))
        XCTAssertEqual(store.pending(for: .visualLanguage), second)
        XCTAssertEqual(store.pendingAll().count, 1, "one slot per key — nothing accumulates")
    }

    func test_twoLanguagesAreTwoSlots() throws {
        _ = try store.stage(.init(kind: .editionBrief("es"), markdown: "es", rationale: nil, proposedAt: Date(), author: "Claude"))
        _ = try store.stage(.init(kind: .editionBrief("fr"), markdown: "fr", rationale: nil, proposedAt: Date(), author: "Claude"))
        XCTAssertEqual(Set(store.pendingAll().map(\.kind)), [.editionBrief("es"), .editionBrief("fr")])
    }

    func test_discardClearsTheSlotAndAnEmptySlotIsNotAnError() throws {
        _ = try store.stage(.init(kind: .visualLanguage, markdown: "x", rationale: nil, proposedAt: Date(), author: "Claude"))
        try store.discard(.visualLanguage)
        XCTAssertNil(store.pending(for: .visualLanguage))
        XCTAssertNoThrow(try store.discard(.visualLanguage))
    }

    func test_stageRefusesWhatValidateRefusesAndWritesNothing() {
        XCTAssertThrowsError(try store.stage(.init(kind: .visualLanguage, markdown: "", rationale: nil,
                                                   proposedAt: Date(), author: "Claude")))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: StatementProposalStore.directoryURL(in: temp.url).path))
    }

    func test_anUnreadableSlotReadsAsNoProposalRatherThanCrashing() throws {
        let dir = StatementProposalStore.directoryURL(in: temp.url)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: StatementProposalStore.fileURL(key: "visual-language", in: temp.url))
        XCTAssertNil(store.pending(for: .visualLanguage))
        XCTAssertTrue(store.pendingAll().isEmpty)
    }

    // MARK: - The event

    func test_theProposalsChangedEventIsProjectScopedWithNoPayload() {
        var received: Notification?
        let token = NotificationCenter.default.addObserver(  // adr-0021-ok: a test observing the post, not a production receiver
            forName: .maughamStatementProposalsChanged, object: nil, queue: nil) { received = $0 }
        defer { NotificationCenter.default.removeObserver(token) }
        MaughamEvent.postStatementProposalsChanged(projectURL: temp.url)
        XCTAssertEqual(received?.userInfo?[MaughamEvent.scopeKindKey] as? String, "project")
        XCTAssertEqual(received?.userInfo?[MaughamEvent.scopeIdKey] as? String,
                       ProjectIdentifier.id(for: temp.url))
    }
}

import XCTest
@testable import Maugham
import MaughamCore

/// The lessons ledger's grammar (editorial letter P2, Task 1): the one place
/// that reads a `## Rulings` row as a lesson, a choice, or a retired entry.
///
/// **Every assertion here is over the ruling's TEXT.** The writer types these
/// entries by hand, so nothing in the grammar may require the canonical
/// `— ruled <d MMM yyyy>, <provenance>` suffix `RulingsSection` writes; a bare
/// `- Cut the throat-clearing paragraph` line is a lesson, and the tests below
/// carry the pairing that proves the grammar never reaches into the provenance.
@MainActor
final class LessonsLedgerTests: XCTestCase {

    // MARK: - Fixtures

    /// A hand-typed ledger carrying one of each shape the grammar has to tell
    /// apart, plus the one that has no provenance suffix at all.
    private let handTyped = """
    What I keep learning.

    ## Rulings

    - Cut the throat-clearing paragraph — ruled 2 Sep 2026, Le Guin
    - Choice: Present tense for the frame story — ruled 2 Sep 2026, Denver
    - Adverbs in dialogue tags (retired 1 Sep 2026) — ruled 1 Sep 2026, Denver
    - Trust the reader with the timeline
    """

    private func date(_ day: Int, _ month: Int, _ year: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    // MARK: - Classification

    /// All four shapes, told apart in one parse, with the essay left alone.
    func test_parseClassifiesEveryShapeItHasToTellApart() {
        let (essay, entries) = LessonsLedger.parse(handTyped)

        XCTAssertEqual(essay, "What I keep learning.")
        XCTAssertEqual(entries.map(\.heading), [
            "Cut the throat-clearing paragraph",
            "Present tense for the frame story",
            "Adverbs in dialogue tags",
            "Trust the reader with the timeline",
        ])
        XCTAssertEqual(entries.map(\.kind), [
            .lesson,
            .choice,
            .retired(date(1, 9, 2026)),
            .lesson,
        ])
    }

    /// The entry keeps the `Ruling` it came from, so a caller that has to write
    /// back addresses it through `RulingsStratum`'s index-at-the-moment rather
    /// than re-deriving the row.
    func test_everyEntryCarriesTheRulingItWasReadFrom() {
        let (_, entries) = LessonsLedger.parse(handTyped)

        XCTAssertEqual(entries.first?.ruling.text,
                       "Cut the throat-clearing paragraph")
        XCTAssertEqual(entries.first?.ruling.provenance, "Le Guin")
        XCTAssertEqual(entries.last?.ruling.provenance, nil,
                       "the hand-typed line has no provenance, and that is legal")
    }

    /// **The grammar reads the TEXT and never the provenance.** A writer whose
    /// provenance happens to spell one of the markers still has a plain lesson;
    /// this is the pairing for the classification above, because a grammar run
    /// over the whole line would read all three of these as something else.
    func test_theGrammarNeverReachesIntoTheProvenance() {
        let markdown = """
        ## Rulings

        - Name the room first — ruled 2 Sep 2026, Choice: Denver
        - Read it aloud — ruled 2 Sep 2026, Le Guin (retired 1 Sep 2026)
        """
        let (_, entries) = LessonsLedger.parse(markdown)

        XCTAssertEqual(entries.map(\.kind), [.lesson, .lesson])
        XCTAssertEqual(entries.map(\.heading), ["Name the room first", "Read it aloud"])
    }

    /// Retirement wins over the choice prefix. A retired choice is nonsense the
    /// writer can fix by hand; classifying it as a live choice would put a
    /// closed decision back in front of them.
    func test_retirementWinsOverTheChoicePrefix() {
        let markdown = """
        ## Rulings

        - Choice: Present tense for the frame story (retired 1 Sep 2026)
        """
        let (_, entries) = LessonsLedger.parse(markdown)

        XCTAssertEqual(entries.map(\.kind), [.retired(date(1, 9, 2026))])
        XCTAssertEqual(entries.map(\.heading), ["Present tense for the frame story"],
                       "and the heading loses both the prefix and the suffix")
    }

    /// A retired suffix whose date does not parse is **still retired** — the
    /// classification holds on the `(retired` marker, and the date is nil. The
    /// alternative puts a retired entry back among the open ones because
    /// somebody typo'd a month.
    func test_aRetiredEntryWithAnUnparseableDateIsStillRetired() {
        let markdown = """
        ## Rulings

        - Adverbs in dialogue tags (retired last Tuesday)
        """
        let (_, entries) = LessonsLedger.parse(markdown)

        XCTAssertEqual(entries.map(\.kind), [.retired(nil)])
        XCTAssertEqual(entries.map(\.heading), ["Adverbs in dialogue tags"])
    }

    // MARK: - The two listings

    /// `open` is the live lesson list: choices and retired entries are not
    /// lessons the writer is still working on.
    func test_openReturnsTheLessonsAndOnlyTheLessonsInFileOrder() {
        XCTAssertEqual(LessonsLedger.open(in: handTyped), [
            "Cut the throat-clearing paragraph",
            "Trust the reader with the timeline",
        ])
    }

    /// CONTROL for the exclusion above: the choice IS in the ledger, and
    /// `choices` is where it shows up — so a green `open` cannot mean the parse
    /// simply dropped the row.
    func test_choicesReturnsTheChoiceThatOpenExcluded() {
        XCTAssertEqual(LessonsLedger.choices(in: handTyped),
                       ["Present tense for the frame story"])
    }

    /// A retired choice appears in neither listing — it is retired, and
    /// retirement wins.
    func test_aRetiredChoiceIsInNeitherListing() {
        let markdown = """
        ## Rulings

        - Choice: Present tense for the frame story (retired 1 Sep 2026)
        """
        XCTAssertEqual(LessonsLedger.open(in: markdown), [])
        XCTAssertEqual(LessonsLedger.choices(in: markdown), [])
    }

    // MARK: - Writing the two markers

    /// `retiredText` then `heading(of:)` round-trips, and the date it writes is
    /// the one `RulingsSection` writes — not a second format that could drift
    /// from the suffix every other ruling in the file carries.
    func test_retiredTextRoundTripsThroughHeadingInRulingsSectionsOwnDateFormat() {
        let retired = LessonsLedger.retiredText(
            "Adverbs in dialogue tags", on: date(2, 9, 2026))

        XCTAssertEqual(retired, "Adverbs in dialogue tags (retired 2 Sep 2026)")
        XCTAssertEqual(LessonsLedger.heading(of: retired), "Adverbs in dialogue tags")
        XCTAssertEqual(
            LessonsLedger.parse("## Rulings\n\n- \(retired)").entries.map(\.kind),
            [.retired(date(2, 9, 2026))],
            "what this function writes must be what the parser reads back")
    }

    /// The same for the choice prefix.
    func test_choiceTextRoundTripsThroughHeading() {
        let choice = LessonsLedger.choiceText("Present tense for the frame story")

        XCTAssertEqual(choice, "Choice: Present tense for the frame story")
        XCTAssertEqual(LessonsLedger.heading(of: choice),
                       "Present tense for the frame story")
        XCTAssertEqual(
            LessonsLedger.parse("## Rulings\n\n- \(choice)").entries.map(\.kind),
            [.choice],
            "what this function writes must be what the parser reads back")
    }

    // MARK: - `matches` (constraint 15)

    /// CONTROL for the two refusals below: the heading the model was briefed on
    /// verbatim matches, and surrounding whitespace is forgiven.
    func test_matchesAcceptsTheHeadingVerbatimAndForgivesWhitespace() {
        XCTAssertTrue(LessonsLedger.matches(
            "Cut the throat-clearing paragraph",
            heading: "Cut the throat-clearing paragraph"))
        XCTAssertTrue(LessonsLedger.matches(
            "  Cut the throat-clearing paragraph  ",
            heading: "Cut the throat-clearing paragraph"))
    }

    /// **Case-sensitive.** The model is briefed on the heading verbatim
    /// (constraint 15), so a returned heading in a different case is a heading
    /// it rewrote — and matching it would attach a lesson's exercise to a row
    /// the writer never named.
    func test_matchesRefusesACaseChange() {
        XCTAssertFalse(LessonsLedger.matches(
            "cut the throat-clearing paragraph",
            heading: "Cut the throat-clearing paragraph"))
    }

    /// And exact after trimming means exact: a trailing period is a different
    /// heading, for the same reason.
    func test_matchesRefusesATrailingPeriod() {
        XCTAssertFalse(LessonsLedger.matches(
            "Cut the throat-clearing paragraph.",
            heading: "Cut the throat-clearing paragraph"))
    }

    // MARK: - No section at all

    /// A ledger the writer has started but not itemized is essay and no
    /// entries — `RulingsSection`'s own C1 rule, inherited rather than
    /// re-decided here.
    func test_aLedgerWithNoItemsIsAllEssay() {
        let (essay, entries) = LessonsLedger.parse("Nothing yet.")
        XCTAssertEqual(essay, "Nothing yet.")
        XCTAssertEqual(entries, [])
        XCTAssertEqual(LessonsLedger.open(in: "Nothing yet."), [])
    }
}

/// The ledger's storage, end to end: `.lessons` walks
/// `StatementConvention.newPath`'s project row straight to `lessons.md` with no
/// new store code, exactly as the edition brief did.
@MainActor
final class LessonsStatementStorageTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    func test_creatingTheLedgerMintsLessonsDotMdAndReadsBackEmpty() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "LessonsLedgerCreate", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value

        let ledger = try await store.createStatement(kind: .lessons, scope: .project)

        XCTAssertEqual(ledger.path, "lessons.md")
        XCTAssertEqual(ledger.kind, .lessons)
        XCTAssertEqual(ledger.scope, .project)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("lessons.md").path))
        XCTAssertEqual(try store.statementText(of: ledger), "",
                       "a brand-new ledger is empty scaffolding; content arrives "
                       + "through the op log")
    }

    /// CONTROL for the row above: a document-scoped ledger has no storage, so
    /// the store refuses rather than minting a second ledger somewhere.
    func test_aDocumentScopedLedgerIsRefusedRatherThanMinted() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "LessonsLedgerRefuse", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        let documentId = try XCTUnwrap(
            store.manifest.structure.first(where: { $0.type == .document })?.id)

        do {
            _ = try await store.createStatement(
                kind: .lessons, scope: .document(documentId))
            XCTFail("a document-scoped lessons ledger has no row in the table")
        } catch let error as ProjectStoreError {
            guard case .statementHasNoStorage = error else {
                return XCTFail("expected .statementHasNoStorage, got \(error)")
            }
        }
        XCTAssertTrue(store.manifest.statements.isEmpty,
                      "a refusal costs nothing — no manifest row")
    }
}

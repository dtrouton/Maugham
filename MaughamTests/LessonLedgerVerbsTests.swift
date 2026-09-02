import XCTest
import MaughamCore
@testable import Maugham

/// **The writer's verbs on the lessons ledger** (editorial letter P2 Task 6,
/// spec §6).
///
/// Driven against a REAL `ProjectStore` over a temp project, `LetterKeepTests`'
/// discipline and for its reason: the whole point of these verbs is what lands
/// in the writer's own file, and the statement machinery that decides that —
/// find-or-create, the rulings stratum, the in-place edit — is exactly what a
/// fake would stub out.
///
/// Every read-back goes through `LessonsLedger`'s grammar over
/// `LessonLedgerVerbs.ledgerText`, never a hand-built expectation about the
/// line's shape: the grammar is what production reads, so a marker the verbs
/// wrote and the grammar cannot see is a defect the assertion must feel.
@MainActor
final class LessonLedgerVerbsTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func loadedNovel(named name: String = "Ledger") async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(named: name, in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return store
    }

    private let provenance = "from Le Guin's letter \u{00b7} Structural \u{00b7} round 2"

    /// The ledger as the app reads it — nil until the writer's first Keep.
    private func ledger(_ store: ProjectStore) -> String? {
        LessonLedgerVerbs.ledgerText(store: store)
    }

    private func open(_ store: ProjectStore) -> [String] {
        LessonsLedger.open(in: ledger(store) ?? "")
    }

    private func choices(_ store: ProjectStore) -> [String] {
        LessonsLedger.choices(in: ledger(store) ?? "")
    }

    private func entries(_ store: ProjectStore) -> [LessonsLedger.Entry] {
        LessonsLedger.parse(ledger(store) ?? "").entries
    }

    private func habit(
        name: String, lesson: String? = nil, exercise: String? = nil
    ) -> Letter.Habit {
        Letter.Habit(name: name, refs: [], cost: "The rhythm flattens.",
                     lesson: lesson, exercise: exercise)
    }

    private func letter(
        habits: [Letter.Habit] = [], retired: [String]? = nil
    ) -> Letter {
        var letter = Letter(
            about: "A house nobody lives in.", oneThing: nil, working: [],
            habits: habits, questions: [], scenes: nil, scenePosition: nil)
        letter.retired = retired
        return letter
    }

    private func run(freshEyes: Bool?) -> CompilerRun {
        CompilerRun(id: "run-1", at: Date(), model: "sonnet", lastOpId: nil,
                    deltaSummary: "d", intentSnapshot: nil, freshEyes: freshEyes)
    }

    // MARK: - Provenance

    /// The lane rides on the provenance because a lesson outlives the letter
    /// that raised it — *which* round noticed it is the one fact a writer
    /// reading their ledger months later cannot recover any other way.
    func test_theProvenanceNamesTheVoiceAndTheLaneWhenThereIsOne() {
        XCTAssertEqual(
            LessonLedgerVerbs.provenance(voice: "Le Guin", lane: "Structural \u{00b7} round 2"),
            "from Le Guin's letter \u{00b7} Structural \u{00b7} round 2")
        XCTAssertEqual(
            LessonLedgerVerbs.provenance(voice: "Le Guin", lane: nil),
            "from Le Guin's letter",
            "a passless run has no lane, and the sentence must not invent one")
        XCTAssertEqual(
            LessonLedgerVerbs.provenance(voice: "Le Guin", lane: "   "),
            "from Le Guin's letter",
            "an empty lane is the same nothing \u{2014} `LetterKeep.laneLine` "
            + "answers \u{201C}\u{201D} for a passless run")
    }

    // MARK: - Keep as lesson

    /// **The first Keep mints the ledger.** `RulingPerformer.rule` is
    /// find-or-create, so nothing has to check whether `lessons.md` is there.
    func test_theFirstKeepMintsTheLedgerAndFilesThePlainHeading() async throws {
        let store = try await loadedNovel()
        XCTAssertNil(
            ledger(store),
            "the premise: a project whose writer has kept nothing has no ledger")

        try await LessonLedgerVerbs.keepAsLesson(
            "Vary the opening.", provenance: provenance, store: store, world: nil)

        XCTAssertEqual(open(store), ["Vary the opening."])
        XCTAssertEqual(
            choices(store), [],
            "a lesson is not a choice \u{2014} the two are the ledger's opposites")
        XCTAssertEqual(
            entries(store).first?.ruling.provenance, provenance,
            "the line must say which letter raised it")
    }

    /// A choice is the same act under `LessonsLedger`'s own marker — never a
    /// second spelling, because the grammar that reads a row is what has to
    /// recognise it.
    func test_makeChoiceFilesUnderTheChoiceMarkerAndNotAsALesson() async throws {
        let store = try await loadedNovel()
        try await LessonLedgerVerbs.makeChoice(
            "Fragments", provenance: provenance, store: store, world: nil)

        XCTAssertEqual(choices(store), ["Fragments"])
        XCTAssertEqual(
            open(store), [],
            "a settled choice is not something the writer is still working on")
        XCTAssertTrue(
            (ledger(store) ?? "").contains(LessonsLedger.choiceText("Fragments")),
            "the marker in the file is the grammar's own. Ledger:\n"
            + (ledger(store) ?? "<none>"))
    }

    /// **One press, every habit** — the seeding gesture §6 names.
    func test_theseAreAllChoicesFilesEveryHeadingInOneAct() async throws {
        let store = try await loadedNovel()
        try await LessonLedgerVerbs.makeChoices(
            ["Fragments", "Sentence-long paragraphs", "Weather first"],
            provenance: provenance, store: store, world: nil)

        XCTAssertEqual(
            choices(store),
            ["Fragments", "Sentence-long paragraphs", "Weather first"],
            "in the order they were offered, so the ledger reads like the letter")
        XCTAssertEqual(open(store), [])
    }

    /// **A plural act that stops part-way says how far it got.** Told only
    /// that it failed, a writer would not know whether pressing again
    /// duplicates what already went in.
    func test_theChoicesStopAtTheFirstRefusalAndSayHowManyLanded() async throws {
        let store = try await loadedNovel()
        do {
            // A blank heading is refused by `makeChoice`'s own guard: the
            // choice marker would otherwise carry it past the performer's.
            try await LessonLedgerVerbs.makeChoices(
                ["Fragments", "   ", "Weather first"],
                provenance: provenance, store: store, world: nil)
            XCTFail("an empty heading must refuse rather than file a blank row")
        } catch let failure as LessonLedgerFailure {
            guard case .someChoicesFiled(let landed, let total, _) = failure else {
                return XCTFail("wrong refusal: \(failure)")
            }
            XCTAssertEqual(landed, 1)
            XCTAssertEqual(total, 3)
        }
        XCTAssertEqual(
            choices(store), ["Fragments"],
            "the one before the refusal landed, and nothing after it did")
    }

    /// **The choice marker must not smuggle a blank heading through.**
    /// `RulingPerformer` sees `Choice: ` and finds words in it; the guard that
    /// makes the refusal honest is `makeChoice`'s own. Control: the same call
    /// with a real heading files.
    func test_aBlankHeadingIsRefusedRatherThanFiledUnderTheChoiceMarker() async throws {
        let store = try await loadedNovel()
        do {
            try await LessonLedgerVerbs.makeChoice(
                "   ", provenance: provenance, store: store, world: nil)
            XCTFail("a choice with no heading is a blank row in the writer's ledger")
        } catch let failure as RulingFailure {
            XCTAssertEqual(failure, .emptyRuling)
        }
        XCTAssertNil(
            ledger(store), "and a refusal must not mint a ledger to refuse into")

        try await LessonLedgerVerbs.makeChoice(
            "Fragments", provenance: provenance, store: store, world: nil)
        XCTAssertEqual(
            choices(store), ["Fragments"],
            "the control: the same verb with something to say files")
    }

    // MARK: - Retire

    /// **In place, dated, never deleted** (spec §6). A retired habit can come
    /// back, and the entry says when it left.
    func test_retireRewritesTheEntryInPlaceAndKeepsItsPosition() async throws {
        let store = try await loadedNovel()
        try await LessonLedgerVerbs.keepAsLesson(
            "Vary the opening.", provenance: provenance, store: store, world: nil)
        try await LessonLedgerVerbs.keepAsLesson(
            "Cut the filter words.", provenance: provenance, store: store, world: nil)

        let day = Calendar.current.date(
            from: DateComponents(year: 2026, month: 9, day: 2, hour: 12))!
        try await LessonLedgerVerbs.retire(
            "Vary the opening.", on: day, store: store, world: nil)

        XCTAssertEqual(
            open(store), ["Cut the filter words."],
            "the retired lesson leaves the live list")
        let rows = entries(store)
        XCTAssertEqual(
            rows.count, 2,
            "and stays in the file \u{2014} a retirement is a rewrite, never a "
            + "revocation. Ledger:\n" + (ledger(store) ?? "<none>"))
        XCTAssertEqual(
            rows.first?.heading, "Vary the opening.",
            "in its original position, which `RulingPerformer.edit` preserves")
        guard case .retired(let date) = rows.first?.kind else {
            return XCTFail("the first row is no longer retired: \(rows)")
        }
        XCTAssertNotNil(date, "the entry says when it left")
        XCTAssertEqual(
            rows.first?.ruling.provenance, provenance,
            "an in-place edit keeps the provenance the line already carried")
    }

    /// **A heading that is not an OPEN lesson refuses and writes nothing.**
    /// Never kept, already retired, or standing as a choice — a press against
    /// any of the three would rewrite a row the writer did not aim at.
    ///
    /// Disable experiment: dropping the `LessonsLedger.kind(of:) == .lesson`
    /// guard turns the choice arm into a silent rewrite of the choice row, and
    /// the "nothing filed" assertion below goes red.
    func test_retiringSomethingThatIsNotAnOpenLessonFilesNothing() async throws {
        let store = try await loadedNovel()
        let day = Date()

        // 1. Never kept — there is no ledger at all yet.
        await assertNotOpen("Vary the opening.", store: store, on: day)
        XCTAssertNil(
            ledger(store), "a refusal must not mint a ledger to refuse into")

        // 2. Standing as a choice.
        try await LessonLedgerVerbs.makeChoice(
            "Fragments", provenance: provenance, store: store, world: nil)
        let beforeChoice = try XCTUnwrap(ledger(store))
        await assertNotOpen("Fragments", store: store, on: day)
        XCTAssertEqual(
            ledger(store), beforeChoice,
            "a choice is a decision already made \u{2014} retiring it would "
            + "rewrite a row the writer never aimed at")

        // 3. Already retired.
        try await LessonLedgerVerbs.keepAsLesson(
            "Vary the opening.", provenance: provenance, store: store, world: nil)
        try await LessonLedgerVerbs.retire(
            "Vary the opening.", on: day, store: store, world: nil)
        let afterFirst = try XCTUnwrap(ledger(store))
        await assertNotOpen("Vary the opening.", store: store, on: day)
        XCTAssertEqual(
            ledger(store), afterFirst,
            "the second retirement would re-date the first, which is the record "
            + "rewriting itself")

        // The control: an open lesson really does retire through the same call.
        try await LessonLedgerVerbs.keepAsLesson(
            "Cut the filter words.", provenance: provenance, store: store, world: nil)
        try await LessonLedgerVerbs.retire(
            "Cut the filter words.", on: day, store: store, world: nil)
        XCTAssertEqual(
            open(store), [],
            "or every refusal above is evidence about nothing")
    }

    /// **Identity is the heading, verbatim** (global constraint 15). A heading
    /// the model re-spelled names no row, and retiring the near-miss's
    /// neighbour would take a lesson off the writer's list on a typo.
    func test_aNearMissNamesNoEntryAndWhitespaceAloneIsForgiven() async throws {
        let store = try await loadedNovel()
        try await LessonLedgerVerbs.keepAsLesson(
            "Vary the opening.", provenance: provenance, store: store, world: nil)
        let before = try XCTUnwrap(ledger(store))

        await assertNotOpen("vary the opening.", store: store, on: Date())
        await assertNotOpen("Vary the opening", store: store, on: Date())
        XCTAssertEqual(
            ledger(store), before,
            "neither a case change nor a dropped stop may address the writer's file")

        // Whitespace alone IS forgiven: it is invisible in the file and
        // nothing about the writer's intent rides on it.
        try await LessonLedgerVerbs.retire(
            "  Vary the opening.  ", on: Date(), store: store, world: nil)
        XCTAssertEqual(open(store), [])
    }

    private func assertNotOpen(
        _ heading: String, store: ProjectStore, on date: Date,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await LessonLedgerVerbs.retire(
                heading, on: date, store: store, world: nil)
            XCTFail("\u{201C}\(heading)\u{201D} is not an open lesson and must refuse",
                    file: file, line: line)
        } catch let failure as LessonLedgerFailure {
            XCTAssertEqual(failure, .notOpen(heading), file: file, line: line)
        } catch {
            XCTFail("wrong refusal: \(error)", file: file, line: line)
        }
    }

    // MARK: - Reading the ledger

    func test_theLedgerTextIsNilUntilSomethingIsKept() async throws {
        let store = try await loadedNovel()
        XCTAssertNil(LessonLedgerVerbs.ledgerText(store: store))
        try await LessonLedgerVerbs.keepAsLesson(
            "Vary the opening.", provenance: provenance, store: store, world: nil)
        XCTAssertTrue(
            (LessonLedgerVerbs.ledgerText(store: store) ?? "")
                .contains("Vary the opening."))
    }

    // MARK: - LessonOffer: what the letter may offer

    /// **The intersection, verbatim, in the letter's order** (constraint 15).
    ///
    /// Disable experiment: returning `letter.retiredHeadings` unfiltered makes
    /// the near-miss and the retired-already arms below go red.
    func test_onlyAHeadingTheLedgerCarriesAsALiveLessonIsRetirable() async throws {
        let store = try await loadedNovel()
        for heading in ["Vary the opening.", "Cut the filter words."] {
            try await LessonLedgerVerbs.keepAsLesson(
                heading, provenance: provenance, store: store, world: nil)
        }
        try await LessonLedgerVerbs.makeChoice(
            "Fragments", provenance: provenance, store: store, world: nil)
        let text = ledger(store)

        XCTAssertEqual(
            LessonOffer.retirable(
                letter(retired: ["Cut the filter words.", "Vary the opening."]),
                ledgerText: text),
            ["Cut the filter words.", "Vary the opening."],
            "the letter's order, not the file's \u{2014} the writer is reading a "
            + "letter")
        XCTAssertEqual(
            LessonOffer.retirable(
                letter(retired: ["vary the opening"]), ledgerText: text), [],
            "a heading the model re-spelled names no live lesson")
        XCTAssertEqual(
            LessonOffer.retirable(letter(retired: ["Fragments"]), ledgerText: text), [],
            "a settled choice is not a lesson to retire")
        XCTAssertEqual(
            LessonOffer.retirable(
                letter(retired: ["Vary the opening."]), ledgerText: nil), [],
            "a project with no ledger has nothing to retire from")
        XCTAssertEqual(
            LessonOffer.retirable(letter(retired: nil), ledgerText: text), [],
            "and a letter that named nothing offers nothing")
    }

    /// The entry text IS the sentence: the lesson the round drew out of the
    /// habit when it offered one, else the habit's own name.
    func test_aHabitsLessonIsItsHeadingAndItsNameIsTheFallback() {
        XCTAssertEqual(
            LessonOffer.lessonHeading(
                for: habit(name: "Filter words", lesson: "Cut the filter words.")),
            "Cut the filter words.")
        XCTAssertEqual(
            LessonOffer.lessonHeading(for: habit(name: "Filter words")),
            "Filter words")
        XCTAssertEqual(
            LessonOffer.lessonHeading(for: habit(name: "Filter words", lesson: "  ")),
            "Filter words",
            "an empty lesson is absent, not the writer's commitment to nothing")
    }

    /// **Keep is withdrawn once the heading stands anywhere** — open, a
    /// choice, or retired. Each is a decision already made about exactly this
    /// sentence, and a second Keep would brief every round twice.
    func test_keepIsWithdrawnOnceTheHeadingStandsInTheLedger() async throws {
        let store = try await loadedNovel()
        try await LessonLedgerVerbs.keepAsLesson(
            "Vary the opening.", provenance: provenance, store: store, world: nil)
        try await LessonLedgerVerbs.makeChoice(
            "Fragments", provenance: provenance, store: store, world: nil)
        try await LessonLedgerVerbs.keepAsLesson(
            "Cut the filter words.", provenance: provenance, store: store, world: nil)
        try await LessonLedgerVerbs.retire(
            "Cut the filter words.", on: Date(), store: store, world: nil)
        let text = ledger(store)

        for standing in ["Vary the opening.", "Fragments", "Cut the filter words."] {
            XCTAssertFalse(
                LessonOffer.keepIsOffered(
                    habit(name: "H", lesson: standing), ledgerText: text),
                "\u{201C}\(standing)\u{201D} already stands in the ledger")
        }
        XCTAssertTrue(
            LessonOffer.keepIsOffered(
                habit(name: "H", lesson: "Weather first."), ledgerText: text),
            "the control: something the ledger has never carried is offered")
        XCTAssertTrue(
            LessonOffer.keepIsOffered(
                habit(name: "H", lesson: "Weather first."), ledgerText: nil),
            "a project with no ledger has decided nothing")
        XCTAssertFalse(
            LessonOffer.keepIsOffered(habit(name: "   "), ledgerText: nil),
            "a habit with nothing to say would file an empty ruling")
    }

    /// **Fresh Eyes only, and only over more than one habit** — the gesture is
    /// a cold read of the whole piece, and over one habit it is *This is a
    /// choice* wearing a plural's clothes.
    func test_theseAreAllChoicesStandsOnlyOnAFreshEyesLetterWithTwoHabits() {
        let two = letter(habits: [habit(name: "A"), habit(name: "B")])
        XCTAssertTrue(LessonOffer.allChoicesIsOffered(two, run: run(freshEyes: true)))
        XCTAssertFalse(
            LessonOffer.allChoicesIsOffered(two, run: run(freshEyes: false)),
            "a warm round read a delta, which proves nothing about a habit")
        XCTAssertFalse(
            LessonOffer.allChoicesIsOffered(two, run: run(freshEyes: nil)),
            "a run recorded before Fresh Eyes existed is not one")
        XCTAssertFalse(LessonOffer.allChoicesIsOffered(two, run: nil))
        XCTAssertFalse(
            LessonOffer.allChoicesIsOffered(
                letter(habits: [habit(name: "A")]), run: run(freshEyes: true)),
            "one habit already has its own button")
    }
}

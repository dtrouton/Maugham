import XCTest
import MaughamCore
@testable import Maugham

/// **Who reads a CHECK** (two loops P1, spec §2).
///
/// `ProjectManifest.authorReader` is the only place Author's ⌘R decides who
/// is reading, and the rule is one sentence: the coach while her seat is
/// held, nobody once it is vacated. The pass a piece sits in on the review
/// board is not an input — that is `RoundEditor`'s question, and asking it
/// here is the defect this split exists to end.
///
/// The round loop's own resolution is pinned by `RoundEditorTests`; what a
/// check actually STAMPS is pinned in `CompilerRunCommandTests`
/// (`test_aCheckUnderTheCoachStampsNoLaneAndNoRoundAndIsSignedByHer`).
final class AuthorReaderTests: XCTestCase {

    // MARK: - Fixtures

    private func manifest(
        passes: [ReviewPass] = [], coachVacated: Bool = false
    ) -> ProjectManifest {
        ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [], reviewPasses: passes,
            coachVacated: coachVacated)
    }

    // MARK: - The two arms

    /// The default this milestone keeps: a writer who never opens Review is
    /// read by the coach.
    func test_aHeldSeatIsTheCoachs() {
        XCTAssertEqual(manifest().authorReader, .coach(ReviewPass.coachPreset))
    }

    /// Vacating the seat is the one off switch: the check goes back to the
    /// all-altitudes reader M2 shipped.
    func test_aVacatedSeatIsNobodys() {
        XCTAssertEqual(manifest(coachVacated: true).authorReader, .nobody)
    }

    /// **The falsifier for the whole split.** A piece parked in Gould's lane
    /// on the review board is STILL the coach's to check — the stage is the
    /// round loop's fact, and a check that read it would sign Author's notes
    /// with an editor the writer never asked for and file them in a lane they
    /// were not standing in. This is the control `PieceReader` would fail: it
    /// answered `.stage(Gould)` for exactly this project.
    func test_aStageRecordedForThePieceDoesNotChangeWhoChecksIt() {
        var memory = ActivePassMemory.empty
        memory.record(piece: "ch-1", passId: "copyedit")
        let m = manifest()

        XCTAssertEqual(m.authorReader, .coach(ReviewPass.coachPreset),
                       "the check loop must not read the board's lane")
        XCTAssertEqual(m.roundEditor(forPiece: "ch-1", memory: memory)?.id, "copyedit",
                       "control: the stage really is recorded \u{2014} the round "
                       + "loop finds it, and only the round loop")
    }

    /// The resolution is per PROJECT: there is no piece in the signature, and
    /// nothing about a piece can change the answer.
    func test_theResolutionIsPerProjectAndNotPerPiece() {
        var memory = ActivePassMemory.empty
        memory.record(piece: "ch-1", passId: "line")
        let m = manifest()

        XCTAssertEqual(m.authorReader, .coach(ReviewPass.coachPreset))
        XCTAssertEqual(m.roundEditor(forPiece: "ch-5", memory: memory), nil,
                       "control: the pieces really do differ for the round loop")
    }

    // MARK: - What each arm answers

    /// **The coach is the one arm with doctrine**, and it travels through
    /// `effectiveBrief` — the M4 P1 rule, because a customized manifest can
    /// store a preset-id seat that predates the field. `ScenePosition.derive`
    /// is what reads it: a pass brief is where a piece opts into scene form.
    ///
    /// **There is no `activePass` any more** (two loops P2 Task 4). She reaches
    /// the briefing as an `AuthorReader.coach` through
    /// `CompilerPrompt.readerSection`, not dressed as a pass.
    func test_theCoachIsTheOneArmWithABriefAndItResolvesEffectively() {
        XCTAssertEqual(manifest().authorReader.brief,
                       ReviewPass.coachPreset.effectiveBrief,
                       "her doctrine must travel through effectiveBrief")
        XCTAssertFalse(manifest().authorReader.isFirstReader,
                       "control: the coach is not the writer's first reader")
    }

    /// **A first reader has no brief, and that is an answer.** Her statement is
    /// who she is, not an instruction about form — read as a pass brief, a
    /// sentence of the writer's prose about her could flip a whole book into
    /// scene form.
    func test_aFirstReaderHasNoBriefAndIsTheArmTheDoseTurnsOn() {
        let reader = AuthorReader.firstReader(
            FirstReader(name: "Tabitha", statement: "She reads on the train."))
        XCTAssertNil(reader.brief,
                     "her description is not doctrine and must not be read as a "
                     + "pass brief")
        XCTAssertTrue(reader.isFirstReader)
    }

    /// **The nobody arm, and the one surviving use of the passless name.**
    /// No reader at all is what the orchestrator reads as the M2 lane: no round
    /// number, no stamp, notes signed "Claude".
    func test_nobodyHasNoBriefAndSignsWithThePasslessName() {
        let reader = manifest(coachVacated: true).authorReader
        XCTAssertNil(reader.brief,
                     "there is nobody here to have doctrine")
        XCTAssertFalse(reader.isFirstReader)
        XCTAssertEqual(reader.editorName, CompilerOrchestrator.passlessEditorName)
        XCTAssertEqual(reader.editorName, "Claude",
                       "control: the constant really is M2's identity")
    }

    /// `editorName` is the byline the Author header and the note's author
    /// both read. The held arm answers the coach's own editor, never the
    /// passless constant.
    func test_editorNameIsTheCoachsForTheHeldArm() {
        XCTAssertEqual(manifest().authorReader.editorName, "Le Guin")
    }
}

/// **The reader roster** (two loops P2, Task 2): the writer's own choice of
/// who reads a check, and the ONE resolution that answers it.
///
/// The table below is the whole rule, and it is asserted cell by cell because
/// every cell is reachable from the picker: a writer can pick a reader and
/// then vacate the seat, or pick the first reader and then clear her name.
/// A stale choice must degrade to the default rule rather than to an empty
/// byline — which is what a reader resolved from a name that is gone would be.
final class AuthorReaderRosterTests: XCTestCase {

    // MARK: - Fixtures

    private static let firstReaderStatement = Statement(
        id: "s-first", kind: .firstReader, scope: .project, path: "first-reader.md")

    private func manifest(
        coachVacated: Bool = false,
        firstReaderName: String? = nil,
        statements: [Statement] = []
    ) -> ProjectManifest {
        ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [], statements: statements,
            reviewPasses: [], coachVacated: coachVacated,
            firstReaderName: firstReaderName)
    }

    /// The resolution with no statement text to load — the shape every cell of
    /// the table below is about, since who she IS is a separate question from
    /// which reader answers.
    private func reader(
        _ m: ProjectManifest, _ choice: AuthorReaderChoice?
    ) -> AuthorReader {
        m.authorReader(choice: choice, statementText: { _ in nil })
    }

    private func named(_ name: String = "Tabitha", _ statement: String? = nil) -> AuthorReader {
        .firstReader(FirstReader(name: name, statement: statement))
    }

    // MARK: - The resolution table, every cell

    /// **{nil, coach, firstReader, nobody} × {seat held, vacated} × {named,
    /// unnamed} — 16 cells, each asserted.**
    ///
    /// The rules the table encodes:
    /// * `nil` (the writer has not chosen) is the default rule: the coach
    ///   while her seat is held, else the first reader if one is named, else
    ///   nobody.
    /// * An explicit `.coach` answers her only while the seat is HELD; a
    ///   choice left over from before the seat was vacated falls through to
    ///   the default rule rather than resolving to a coach who is not there.
    /// * `.firstReader` answers her only while a name is set, and falls
    ///   through for the same reason.
    /// * `.nobody` is the one choice with no premise to lose: it always
    ///   answers nobody.
    func test_everyCellOfTheResolutionTable() {
        let cells: [(AuthorReaderChoice?, Bool, Bool, AuthorReader, String)] = [
            // choice, seat held, named, expected, why
            (nil, true, true, .coach(ReviewPass.coachPreset),
             "unchosen: the held seat outranks a named reader"),
            (nil, true, false, .coach(ReviewPass.coachPreset),
             "unchosen: the held seat is the default"),
            (nil, false, true, named(),
             "unchosen: with the seat vacated a named reader is next"),
            (nil, false, false, .nobody,
             "unchosen: no seat and no name is M2's lane"),

            (.coach, true, true, .coach(ReviewPass.coachPreset),
             "chosen coach, seat held"),
            (.coach, true, false, .coach(ReviewPass.coachPreset),
             "chosen coach, seat held, nobody else named"),
            (.coach, false, true, named(),
             "a stale coach choice over a vacated seat falls to the default rule"),
            (.coach, false, false, .nobody,
             "a stale coach choice with nothing to fall back on is nobody"),

            (.firstReader, true, true, named(),
             "chosen first reader outranks the held seat \u{2014} the whole point"),
            (.firstReader, true, false, .coach(ReviewPass.coachPreset),
             "a first reader chosen and then unnamed falls to the default rule"),
            (.firstReader, false, true, named(),
             "chosen first reader, seat vacated"),
            (.firstReader, false, false, .nobody,
             "chosen but unnamed, with no seat either"),

            (.nobody, true, true, .nobody, "nobody is chosen over a held seat"),
            (.nobody, true, false, .nobody, "nobody is chosen over a held seat"),
            (.nobody, false, true, .nobody, "nobody is chosen over a named reader"),
            (.nobody, false, false, .nobody, "nobody, with nothing else on offer"),
        ]

        for (choice, held, isNamed, expected, why) in cells {
            let m = manifest(
                coachVacated: !held,
                firstReaderName: isNamed ? "Tabitha" : nil)
            XCTAssertEqual(
                reader(m, choice), expected,
                "choice: \(String(describing: choice)), seat held: \(held), "
                + "named: \(isNamed) \u{2014} \(why)")
        }
    }

    /// **The bare property is the default rule and nothing else** — it is what
    /// the surfaces that only need a NAME read, and it must keep answering
    /// exactly what `authorReader(choice: nil, statementText: { _ in nil })`
    /// answers. Two spellings of the default rule is how the header comes to
    /// name a reader the run was not briefed on.
    func test_theBarePropertyIsTheDefaultRuleWithNoStatementText() {
        let cases = [
            manifest(),
            manifest(coachVacated: true),
            manifest(firstReaderName: "Tabitha"),
            manifest(coachVacated: true, firstReaderName: "Tabitha"),
            manifest(coachVacated: true, firstReaderName: "Tabitha",
                     statements: [Self.firstReaderStatement]),
        ]
        for m in cases {
            XCTAssertEqual(m.authorReader, reader(m, nil),
                           "the property and the nil choice are one rule")
        }
        XCTAssertEqual(
            manifest(coachVacated: true, firstReaderName: "Tabitha",
                     statements: [Self.firstReaderStatement]).authorReader,
            named(),
            "and it loads no statement text \u{2014} a name is all it promises")
    }

    // MARK: - Who she is

    /// Her description is the whole markdown of `first-reader.md`, loaded at
    /// the keystroke through the caller's own reader, so the model knows
    /// nothing about stores.
    func test_theStatementTextIsLoadedForANamedFirstReader() {
        let m = manifest(coachVacated: true, firstReaderName: "Tabitha",
                         statements: [Self.firstReaderStatement])
        var asked: [String] = []
        let resolved = m.authorReader(choice: nil, statementText: {
            asked.append($0.id)
            return "She reads crime, and hates a prologue."
        })
        XCTAssertEqual(resolved, named("Tabitha", "She reads crime, and hates a prologue."))
        XCTAssertEqual(asked, ["s-first"],
                       "the project-scope first-reader statement is the one asked for")
    }

    /// **A name with no statement is a valid reader** (§4.3): the writer named
    /// her and has not described her yet. Resolving to `nobody` here would
    /// silently discard a reader the writer picked.
    func test_aNamedFirstReaderWithNoStatementResolvesWithNilDescription() {
        let m = manifest(coachVacated: true, firstReaderName: "Tabitha")
        var asked = 0
        let resolved = m.authorReader(choice: nil, statementText: { _ in
            asked += 1
            return "unreachable"
        })
        XCTAssertEqual(resolved, named("Tabitha", nil))
        XCTAssertEqual(asked, 0,
                       "with no statement in the manifest there is nothing to load")
    }

    /// An unreadable statement log is a reader with no description, not a
    /// crash and not a lost reader: the name is manifest metadata and is still
    /// true whatever the log says.
    func test_aThrowingStatementReaderLeavesHerDescriptionEmpty() {
        struct Unreadable: Error {}
        let m = manifest(coachVacated: true, firstReaderName: "Tabitha",
                         statements: [Self.firstReaderStatement])
        XCTAssertEqual(
            m.authorReader(choice: nil, statementText: { _ in throw Unreadable() }),
            named("Tabitha", nil))
    }

    /// A statement whose prose the writer has emptied is the same state as one
    /// they never wrote — one description, not two spellings of none.
    func test_aBlankStatementIsNoDescription() {
        let m = manifest(coachVacated: true, firstReaderName: "Tabitha",
                         statements: [Self.firstReaderStatement])
        XCTAssertEqual(
            m.authorReader(choice: nil, statementText: { _ in "   \n\t " }),
            named("Tabitha", nil))
    }

    // MARK: - The byline

    /// `editorName` for all three arms: the coach's effective editor, the
    /// first reader's own name, and the passless constant.
    func test_editorNameForEveryArm() {
        XCTAssertEqual(AuthorReader.coach(ReviewPass.coachPreset).editorName, "Le Guin")
        XCTAssertEqual(named("Tabitha", "anything").editorName, "Tabitha",
                       "a first reader signs with her name \u{2014} she has no "
                       + "editor persona to resolve")
        XCTAssertEqual(AuthorReader.nobody.editorName,
                       CompilerOrchestrator.passlessEditorName)
        XCTAssertEqual(AuthorReader.nobody.editorName, "Claude",
                       "control: the constant really is M2's identity")
    }

    /// **The resolution is per PROJECT and reads nothing about a piece.** The
    /// falsifier P1 shipped, restated over the new arm: a first reader is the
    /// book's, not a chapter's.
    func test_aRecordedStageStillChangesNothingAboutWhoChecks() {
        var memory = ActivePassMemory.empty
        memory.record(piece: "ch-1", passId: "copyedit")
        let m = manifest(coachVacated: true, firstReaderName: "Tabitha")

        XCTAssertEqual(reader(m, .firstReader), named())
        XCTAssertEqual(m.roundEditor(forPiece: "ch-1", memory: memory)?.id, "copyedit",
                       "control: the stage really is recorded")
    }
}

/// The write path for the choice: a named verb on the UI-state store, so the
/// picker has one door and every window on the project sees the same pick.
@MainActor
final class AuthorReaderChoiceStoreTests: XCTestCase {

    func test_theChoiceIsWrittenAndClearedThroughTheStoresVerb() async throws {
        let temp = try TempDirectory()
        let url = try await ProjectFactory.createNovelProject(
            named: "Roster", in: temp.url)
        let store = try await DocumentStore.open(url: url)

        XCTAssertNil(store.uiState.authorReaderChoice, "premise: unchosen")

        store.setAuthorReaderChoice(.firstReader)
        XCTAssertEqual(store.uiState.authorReaderChoice, .firstReader)

        store.setAuthorReaderChoice(nil)
        XCTAssertNil(store.uiState.authorReaderChoice,
                     "clearing it returns the project to the default rule, "
                     + "which is not the same as picking .nobody")
    }
}

/// A hand-edited manifest is a writer of the name too, and a reader whose
/// name is a space is a byline nobody can read. `setFirstReaderName` already
/// maps a blank to nil; the resolution does not depend on it having been the
/// only way in.
extension AuthorReaderRosterTests {
    func test_aBlankNameIsNoFirstReader() {
        let m = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [], coachVacated: true,
            firstReaderName: "   ")
        XCTAssertEqual(m.authorReader(choice: .firstReader, statementText: { _ in nil }),
                       .nobody)
    }

    func test_aPaddedNameIsTrimmedOnTheWayThrough() {
        let m = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [], coachVacated: true,
            firstReaderName: "  Tabitha  ")
        XCTAssertEqual(m.authorReader(choice: nil, statementText: { _ in nil }),
                       .firstReader(FirstReader(name: "Tabitha", statement: nil)))
    }
}

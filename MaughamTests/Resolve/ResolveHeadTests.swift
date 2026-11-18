import XCTest
import MaughamCore
@testable import Maugham

/// **To resolve's head** (shell plan 2, Task 5): for a piece, where it stands,
/// the latest letter and Run; at Book or Part scope, one line counting the
/// pieces with something open.
///
/// Read anywhere, act only on the open piece (Denver, 2026-11-18): the head
/// SHOWS a piece's standing and letter whether or not it is open, offers Run
/// and the letter's exercise only on the open piece, and offers the ladder's
/// menus wherever the posture allows (a pass state is a manifest value, not a
/// `Document` method). Pure decisions and censuses (tripwire 33).
@MainActor
final class ResolveHeadTests: XCTestCase {

    // MARK: - Builders

    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    private func letter(_ oneThing: String?) -> Letter {
        Letter(about: "A ghost story told through weather.", oneThing: oneThing,
               working: [], habits: [], questions: [], scenes: nil, scenePosition: nil)
    }

    private func run(_ id: String, at offset: TimeInterval, kind: RunKind,
                     letter: Letter?, passId: String? = nil,
                     readerName: String? = nil) -> CompilerRun {
        CompilerRun(id: id, at: t.addingTimeInterval(offset), model: "m", lastOpId: nil,
                    deltaSummary: "", intentSnapshot: nil, passId: passId,
                    round: kind == .round ? 1 : nil, kind: kind,
                    readerName: readerName, letter: letter)
    }

    private func note(_ id: String, on docId: String) -> ResolveItem {
        .note(ProjectAnnotation(docId: docId, annotation: Annotation(
            id: id, kind: .comment, paragraphId: "aa11", body: id, suggestedText: nil,
            priorText: nil, createdAt: t, createdBySession: nil, status: .open,
            userResponse: nil, resolvedAt: nil, isStale: false)))
    }

    private func todo(_ id: String, on docId: String?) -> ResolveItem {
        .todo(WriterTask(id: id, kind: .paneCreated,
                         anchor: docId.map { TaskAnchor(docId: $0, paragraphId: nil) },
                         body: id, status: .open, priority: 0, parentTaskId: nil,
                         createdAt: t, createdBySession: nil))
    }

    private func strain(_ id: String, on docId: String) -> ResolveItem {
        .finding(docId: docId, Diagnostic(
            id: id, docId: docId, anchor: nil, body: id, category: nil,
            runId: "run-1", kind: .conformanceStrain))
    }

    private var bookAuthor: Posture { Posture(.unrestricted) }
    private var reviewer: Posture {
        Posture(LocalWritePermit(permit: .reviewer, actor: .author,
                                 documentClass: .piece("doc-a")))
    }

    private let book = ResolveScope.pieces(docIds: ["doc-a", "doc-b", "doc-c"],
                                           includesBookLevel: true)

    // MARK: - The latest letter

    func test_theLatestLetterIsTheNewerRunWithALetter() {
        let check = run("c", at: 0, kind: .check, letter: letter("Check's."))
        let round = run("r", at: 60, kind: .round, letter: letter("Round's."))
        XCTAssertEqual(ResolveHead.latestLetter(check: check, round: round)?.id, "r")
        XCTAssertEqual(ResolveHead.latestLetter(check: round, round: check)?.id, "r",
                       "newer by `at`, whichever slot it came from")
        XCTAssertEqual(ResolveHead.latestLetter(check: check, round: nil)?.id, "c")
        XCTAssertEqual(ResolveHead.latestLetter(check: nil, round: round)?.id, "r")
        XCTAssertNil(ResolveHead.latestLetter(check: nil, round: nil))
    }

    func test_aRunWithAnEmptyLetterYieldsToTheOther() {
        let check = run("c", at: 0, kind: .check, letter: letter("Check's."))
        let emptyRound = run("r", at: 60, kind: .round, letter: letter(nil))
        let noLetterRound = run("r2", at: 60, kind: .round, letter: nil)
        XCTAssertTrue(letter(nil).isEmpty, "premise: a say-back alone is an empty letter")
        XCTAssertEqual(ResolveHead.latestLetter(check: check, round: emptyRound)?.id, "c",
                       "a newer run whose letter says nothing does not hide an older one")
        XCTAssertEqual(ResolveHead.latestLetter(check: check, round: noLetterRound)?.id, "c")
        XCTAssertNil(ResolveHead.latestLetter(
            check: run("c", at: 0, kind: .check, letter: nil), round: emptyRound),
                     "no letter at all draws no letter")
    }

    func test_aTieGoesToTheCheck() {
        let check = run("c", at: 30, kind: .check, letter: letter("Check's."))
        let round = run("r", at: 30, kind: .round, letter: letter("Round's."))
        XCTAssertEqual(ResolveHead.latestLetter(check: check, round: round)?.id, "c")
    }

    /// Tripwire 34: each letter is signed by its own loop. A check's by the
    /// reader the RUN was read under (else today's `AuthorReader`); a round's
    /// by its pass's editor, never by the check's reader.
    func test_eachLetterIsSignedByItsOwnLoop() {
        let gould = ReviewPass(id: "copyedit", name: "Copyedit", editorName: "Gould")
        let reader = AuthorReader.coach(ReviewPass.coachPreset)
        let check = run("c", at: 0, kind: .check, letter: letter("x"), readerName: "Ruth")
        XCTAssertEqual(ResolveHead.letterVoice(run: check, reader: reader, passes: [gould]),
                       "Ruth", "the run's own byline")
        let unstamped = run("c", at: 0, kind: .check, letter: letter("x"))
        XCTAssertEqual(ResolveHead.letterVoice(run: unstamped, reader: reader, passes: [gould]),
                       reader.editorName, "a record from before the stamp: the live reader")
        let round = run("r", at: 0, kind: .round, letter: letter("x"), passId: "copyedit",
                        readerName: "Ruth")
        XCTAssertEqual(ResolveHead.letterVoice(run: round, reader: reader, passes: [gould]),
                       "Gould", "a round is its pass's editor's, never the check's reader")
    }

    // MARK: - Book or Part

    func test_theBookLineCountsPiecesNotItems() {
        let items = [note("n1", on: "doc-a"), note("n2", on: "doc-a"),
                     strain("s1", on: "doc-a"), todo("t1", on: "doc-b")]
        XCTAssertEqual(ResolveHead.openPieceCount(items, scope: book), 2)
        XCTAssertEqual(ResolveHead.bookLine(openPieces: 0), "Nothing to resolve")
        XCTAssertEqual(ResolveHead.bookLine(openPieces: 1), "1 piece has something to resolve")
        XCTAssertEqual(ResolveHead.bookLine(openPieces: 2), "2 pieces have something to resolve")
    }

    func test_bookLevelTodosAndFiguresAreNotCountedAsPieces() {
        let figure = DocumentClass.figureDocIdPrefix + "-01HZZ"
        XCTAssertTrue(DocumentClass.isFigureDocId(figure), "premise: a figure's id")
        let items = [todo("t1", on: nil), note("fn", on: figure), note("n", on: "doc-c")]
        XCTAssertEqual(ResolveHead.openPieceCount(items, scope: book), 1,
                       "the Book's own to-do and a figure's note are not pieces")
        XCTAssertEqual(ResolveHead.openPieceCount([note("x", on: "doc-z")], scope: book), 0,
                       "a piece the scope does not hold is not counted")
    }

    // MARK: - What the head is, per scope

    func test_theHeadsShapeFollowsTheScope() {
        XCTAssertEqual(ResolveHead.shape(.piece(docId: "doc-a", includesBookLevel: false)),
                       .piece(docId: "doc-a"))
        XCTAssertEqual(ResolveHead.shape(.piece(docId: "s", includesBookLevel: true)),
                       .piece(docId: "s"), "a one-script screenplay's Book is its piece")
        XCTAssertEqual(ResolveHead.shape(book), .count)
        XCTAssertEqual(ResolveHead.shape(.pieces(docIds: ["a"], includesBookLevel: false)), .count,
                       "a Part counts too")
        XCTAssertEqual(ResolveHead.shape(.figure(id: "fig-1")), .nothing)
        XCTAssertEqual(ResolveHead.shape(.elsewhere(docId: "r")), .nothing)
        XCTAssertEqual(ResolveHead.shape(.outside), .nothing)
    }

    // MARK: - What the head offers: open × posture

    func test_theOpenPieceOffersEverythingThePostureAllows() {
        let offers = ResolveHead.offers(mayAct: true, posture: bookAuthor)
        XCTAssertEqual(offers, ResolveHeadOffers(
            runRound: true, runCheck: true, rulesOnPasses: true,
            acceptsExercise: true, opensThePiece: false))
    }

    func test_aPieceNotOpenOffersTheLadderButNoRunAndOneOpenLine() {
        let offers = ResolveHead.offers(mayAct: false, posture: bookAuthor)
        XCTAssertEqual(offers, ResolveHeadOffers(
            runRound: false, runCheck: false, rulesOnPasses: true,
            acceptsExercise: false, opensThePiece: true),
            "Run starts a run on the piece and is hidden; a pass state is a manifest "
            + "write and stays offered; the head says how to act instead")
    }

    /// Review Focus 2: a narrowed or shared book whose posture refuses.
    func test_aRefusingPostureHidesTheRoundsRunAndTheLaddersMenus() {
        XCTAssertFalse(reviewer.allows(.runRound), "premise")
        XCTAssertFalse(reviewer.allows(.setPassState), "premise")
        let open = ResolveHead.offers(mayAct: true, posture: reviewer)
        XCTAssertFalse(open.runRound, "the round's Run is hidden where the posture refuses it")
        XCTAssertFalse(open.rulesOnPasses, "and the ladder draws plain rows")
        XCTAssertTrue(open.runCheck, "a check is not gated by posture (`Posture.Verb.runRound`)")
        XCTAssertEqual(open.acceptsExercise, reviewer.allows(.task))
        XCTAssertFalse(ResolveHead.offers(mayAct: false, posture: reviewer).rulesOnPasses)
    }

    func test_anAcceptedExerciseIsOfferedOnlyOnTheOpenPiece() {
        XCTAssertTrue(ResolveHead.offers(mayAct: true, posture: bookAuthor).acceptsExercise)
        XCTAssertFalse(ResolveHead.offers(mayAct: false, posture: bookAuthor).acceptsExercise,
                       "a task is a `Document` method: only on the open piece")
        let source = try? headSource()
        XCTAssertTrue(source?.contains("onAcceptExercise: offers.acceptsExercise") == true,
                      "the head's letter takes its exercise offer from the decision")
    }

    // MARK: - The round's report line with no document

    func test_aClosedPiecesRoundReportIsItsTimingOnly() {
        let timing = RunTiming(elapsed: 42, model: "m", effort: "standard")
        var round = run("r", at: 0, kind: .round, letter: nil, passId: "copyedit")
        round.timing = timing
        XCTAssertEqual(ResolveHead.roundReportLine(history: [], run: round, annotations: nil,
                                                   passes: []),
                       RoundNarrative.readInLine(timing),
                       "with no queue to count, no since-round sentence is made up")
        XCTAssertNil(ResolveHead.roundReportLine(history: [], run: nil, annotations: nil,
                                                 passes: []))
        XCTAssertEqual(ResolveHead.roundReportLine(history: [], run: round, annotations: [],
                                                   passes: []),
                       ReviewRoundCockpit.reportLine(history: [], run: round, annotations: [],
                                                     passes: []),
                       "with a queue, the cockpit's own line")
    }

    // MARK: - Censuses

    private func headSource() throws -> String {
        try String(contentsOf: SourceTree.repoRoot.appendingPathComponent(
            "Maugham/Views/Resolve/ResolveHead.swift"), encoding: .utf8)
    }

    /// Both Run buttons post the command (one delivery path): an unopened
    /// piece gets the command's own `.pieceWouldNotOpen` answer.
    func test_theHeadsRunButtonsPostTheCommands() throws {
        let code = SourceScan.codeLines(of: try headSource()).joined(separator: "\n")
        XCTAssertTrue(code.contains("MaughamEvent.postRun(freshEyes ? .freshEyes : .runRound)"),
                      "the round's Run posts the round")
        XCTAssertFalse(code.contains("runRequested("),
                       "no second delivery path from the head")
        let header = SourceScan.codeLines(of: try String(
            contentsOf: SourceTree.repoRoot.appendingPathComponent(
                "Maugham/Views/DiagnosticsPaneHeader.swift"), encoding: .utf8))
            .joined(separator: "\n")
        XCTAssertTrue(header.contains("MaughamEvent.postRun(.reread)"),
                      "the check's Reread posts the check, cold")
        XCTAssertFalse(header.contains("runRequested("),
                       "the header no longer calls the orchestrator itself")
    }

    /// The head never loads: no `Document.load`, no transient load, and the
    /// letter's text comes from the snapshot.
    func test_theHeadLoadsNothing() throws {
        let code = SourceScan.codeLines(of: try headSource()).joined(separator: "\n")
        for banned in ["Document.load(", "withAnnotationDocument", "currentParagraphState("] {
            XCTAssertFalse(code.contains(banned), "the head must not read through \(banned)")
        }
        XCTAssertTrue(code.contains("currentText: { snapshot.paragraphText[$0] }"),
                      "the letter's current text is the snapshot's")
    }

    /// Tripwire 34 in the head: the check's reader is `AuthorReader` (an
    /// input) and the round's lane is the piece's recorded active pass; the
    /// round's mount never reads the seat, and the check's never the memory.
    func test_theHeadKeepsTheTwoLoopsApart() throws {
        let code = SourceScan.codeLines(of: try headSource()).joined(separator: "\n")
        XCTAssertFalse(code.contains("effectiveCoach"),
                       "a round is its stage editor's; the seat is never read here")
        XCTAssertTrue(code.contains("validatedActivePass(forPiece:"),
                      "the round's lane is the piece's recorded pass")
    }
}

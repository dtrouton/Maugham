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

    private let noOwners: [String: String?] = [:]
    private let wholeBook = DocumentClass.figureDocIdPrefix + "-01WHOLE"
    private let owned = DocumentClass.figureDocIdPrefix + "-01OWNED"

    private func lines(_ items: [ResolveItem],
                       owners: [String: String?] = [:]) -> [String] {
        ResolveHead.bookLines(ResolveHead.bookCount(items, scope: book, figureOwners: owners))
    }

    func test_theBookLineCountsPiecesNotItems() {
        let items = [note("n1", on: "doc-a"), note("n2", on: "doc-a"),
                     strain("s1", on: "doc-a"), todo("t1", on: "doc-b")]
        XCTAssertEqual(ResolveHead.bookCount(items, scope: book, figureOwners: noOwners),
                       ResolveBookCount(pieces: 2, bookTodos: 0, bookFigures: 0))
        XCTAssertEqual(lines(items), ["2 pieces have something open"])
        XCTAssertEqual(lines([note("n", on: "doc-c")]), ["1 piece has something open"])
    }

    /// Controller ruling M3: the Book's own to-dos are counted, on a line of
    /// their own.
    func test_onlyBookLevelToDosOpenSaysSo() {
        XCTAssertEqual(lines([todo("t1", on: nil), todo("t2", on: nil)]), ["Book to-dos open"])
    }

    func test_piecesAndBookToDosOpenSayBoth() {
        XCTAssertEqual(lines([todo("t1", on: nil), note("n", on: "doc-a"),
                              todo("t2", on: "doc-b")]),
                       ["2 pieces have something open", "Book to-dos open"])
    }

    func test_nothingOpenSaysNothingToResolve() {
        XCTAssertEqual(lines([]), ["Nothing to resolve"])
    }

    /// A figure's note counts on the piece that owns it (the board's rule);
    /// a figure no piece owns is the Book's, on its own line. Either way the
    /// head never says "Nothing to resolve" over a list with rows in it.
    func test_figureNotesCountOnTheirOwnerOrTheBook() {
        XCTAssertTrue(DocumentClass.isFigureDocId(owned), "premise: a figure's id")
        let owners: [String: String?] = [owned: "doc-a", wholeBook: nil]
        XCTAssertEqual(lines([note("f", on: owned)], owners: owners),
                       ["1 piece has something open"])
        XCTAssertEqual(lines([note("f", on: owned), note("n", on: "doc-a")], owners: owners),
                       ["1 piece has something open"], "one piece, counted once")
        XCTAssertEqual(lines([note("w", on: wholeBook)], owners: owners),
                       ["Book figures have notes open"])
        XCTAssertEqual(ResolveHead.bookCount([note("x", on: "doc-z")], scope: book,
                                             figureOwners: owners).pieces, 0,
                       "a piece the scope does not hold is not counted")
    }

    /// Never "Nothing to resolve" above a non-empty list, whatever it holds.
    func test_aNonEmptySnapshotNeverReadsNothingToResolve() {
        let owners: [String: String?] = [owned: "doc-a", wholeBook: nil]
        let kinds: [ResolveItem] = [note("n", on: "doc-a"), strain("s", on: "doc-b"),
                                    todo("t", on: "doc-c"), todo("b", on: nil),
                                    note("f", on: owned), note("w", on: wholeBook)]
        for item in kinds {
            XCTAssertFalse(lines([item], owners: owners).contains(ResolveHead.nothingLine),
                           "\(item.id) is open, so something is said about it")
        }
    }

    // MARK: - The letter's identity (fix round 1, I1)

    /// The letter block's state lives and dies with one letter: a new piece
    /// or a new latest run (the check's letter giving way to the round's on
    /// the same piece) is a new identity, so no refusal outlives its letter.
    func test_theLetterBlockIsKeyedByPieceAndRun() {
        let same = ResolveHead.letterIdentity(docId: "doc-a", runId: "check-1")
        XCTAssertEqual(same, ResolveHead.letterIdentity(docId: "doc-a", runId: "check-1"))
        XCTAssertNotEqual(same, ResolveHead.letterIdentity(docId: "doc-a", runId: "round-1"),
                          "the check's letter flipping to the round's is a new block")
        XCTAssertNotEqual(same, ResolveHead.letterIdentity(docId: "doc-b", runId: "check-1"),
                          "another piece is a new block")
    }

    func test_theLettersStateIsHeldByTheKeyedBlockOnly() throws {
        let source = try headSource()
        let head = try XCTUnwrap(
            source.range(of: "struct ResolveHeadView: View {").map { String(source[$0.lowerBound...]) }
                .flatMap { s in s.range(of: "// MARK: - The head's letter block").map { String(s[..<$0.lowerBound]) } },
            "the head's declaration is bounded by the letter block's")
        let code = SourceScan.codeLines(of: head).joined(separator: "\n")
        XCTAssertFalse(code.contains("@State"), "the head holds no letter state of its own")
        XCTAssertTrue(code.contains("HeadLetterBlock("), "the head mounts the keyed block")
        XCTAssertTrue(code.contains(".id(ResolveHead.letterIdentity(docId: docId, runId: run.id))"),
                      "keyed by the piece and the latest run")
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

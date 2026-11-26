import XCTest
@testable import MaughamCore
@testable import Maugham

/// **To resolve for a piece read in a language** (shell p4 Task 9): the
/// scope, its list, its head's decisions, Earlier letters at a piece's
/// ordinary head, and the census that the translation review pane it replaces
/// is gone with every capability homed. Pure functions, one real round ledger
/// and one real translation store on disk, and source censuses — nothing is
/// pressed and waited on (tripwire 33).
@MainActor
final class ResolvePieceInLanguageTests: XCTestCase {

    // MARK: - Builders

    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    private let structure: [StructureItem] = [
        StructureItem(id: "doc-a", title: "One", type: .document, path: "one.md"),
        StructureItem(id: "doc-b", title: "Two", type: .document, path: "two.md"),
    ]

    private func note(_ id: String, on docId: String, language: String?,
                      kind: AnnotationKind = .query, status: AnnotationStatus = .open,
                      paragraphId: String? = "aa11") -> ProjectAnnotation {
        ProjectAnnotation(docId: docId, annotation: Annotation(
            id: id, kind: kind, paragraphId: paragraphId, body: id, suggestedText: nil,
            priorText: nil, createdAt: t, createdBySession: nil, status: status,
            userResponse: nil, resolvedAt: nil, isStale: false, language: language))
    }

    private func departure(_ id: String, paragraphId: String = "aa11") -> TranslationRound.DepartureRecord {
        TranslationRound.DepartureRecord(id: id, paragraphId: paragraphId, verdict: "drifted",
                                         kind: "register", note: "Softer.", gloss: "It whispers.",
                                         outcome: nil)
    }

    private func round(_ number: Int, docId: String, language: String = "sr",
                       summary: String? = nil, departures: [String] = [],
                       glossary: [String] = [], failed: Bool = false,
                       cancelled: Bool = false) -> TranslationRound {
        var round = TranslationRound(number: number, language: language, docId: docId,
                                     startedAt: t.addingTimeInterval(TimeInterval(number) * 60))
        round.endedAt = round.startedAt.addingTimeInterval(30)
        round.summary = summary
        round.departures = departures.map { departure($0) }
        round.glossaryProposals = glossary.map {
            TranslationRound.GlossaryProposalRecord(term: $0, rendering: "\($0)-sr", reason: "", adopted: false)
        }
        if failed { round.legs = [.init(leg: .read, status: .failed, reason: "the session ended")] }
        if cancelled { round.legs = [.init(leg: .read, status: .cancelled)] }
        return round
    }

    private func problem(_ message: String) -> TectonicLogParser.Diagnostic {
        TectonicLogParser.Diagnostic(level: .error, file: nil, line: nil, message: message,
                                     contextLines: [], pieceID: nil, paragraphID: nil)
    }

    private func proposal() -> DesignProposalStore.Proposal {
        DesignProposalStore.Proposal(id: "p1", designerName: "Tschichold", round: 1, language: nil,
                                     created: t, status: .pending, specMarkdown: "", filePaths: [],
                                     sampleResult: nil, revertNote: nil)
    }

    private func scope(_ subject: WindowSubject, switched: String?) -> ResolveScope {
        ResolveScope.of(subject.faces,
                        readIn: ReadingLanguage.of(subject: subject, switched: switched, sourceLanguage: "en"),
                        sourceLanguage: "en", structure: structure, projectType: .novel)
    }

    private func makeProject() throws -> URL {
        let root = TestTemp.root.appendingPathComponent("PieceInLanguage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - The scope and its list

    /// **A piece read in Serbian lists only Serbian items**: its own Serbian
    /// questions and its latest Serbian round's changes and glossary
    /// proposals — never another language's question, a source note, a
    /// to-do, another chapter's item, the book's design proposal or a
    /// compile's problem.
    func test_aPieceReadInSerbianListsOnlySerbianItems() {
        let read = scope(WindowSubject(open: .item("doc-a"), faces: .item("doc-a")), switched: "sr")
        let annotations = ProjectAnnotationsSnapshot(
            annotations: [note("q-sr", on: "doc-a", language: "sr"),
                          note("q-SR-case", on: "doc-a", language: "SR"),
                          note("q-es", on: "doc-a", language: "es"),
                          note("source", on: "doc-a", language: nil, kind: .comment),
                          note("q-sr-other", on: "doc-b", language: "sr"),
                          note("q-sr-settled", on: "doc-a", language: "sr", status: .accepted)],
            unreadableDocIds: [], sequences: ["doc-a": ["aa11"], "doc-b": ["bb22"]])
        let todo = WriterTask(id: "t1", kind: .paneCreated, anchor: TaskAnchor(docId: "doc-a", paragraphId: nil),
                              body: "t", status: .open, priority: 0, parentTaskId: nil,
                              createdAt: t, createdBySession: nil)
        let snapshot = ResolveReader.snapshot(
            scope: read, annotations: annotations, tasks: [todo],
            findings: ["doc-a": [Diagnostic(id: "s1", docId: "doc-a", anchor: nil, body: "s", category: nil,
                                            runId: "r", kind: .conformanceStrain)]],
            paragraphText: ["aa11": "One."], figureOwners: [:])
        XCTAssertEqual(snapshot.items.map(\.id),
                       ["note:doc-a/q-sr", "note:doc-a/q-SR-case"],
                       "its questions in Serbian, and nothing the source's list holds")
        XCTAssertEqual(snapshot.paragraphText, ["aa11": "One."], "its text titles its paragraph groups")

        var edition = ResolveEditionItems.Read(language: "sr",
                                               rounds: ["doc-a": round(4, docId: "doc-a", departures: ["d1"],
                                                                       glossary: ["fog"]),
                                                        "doc-b": round(3, docId: "doc-b", departures: ["d2"])],
                                               proposals: [proposal()], problems: [problem("x")])
        edition.hasRounds = true
        guard case .pieceInLanguage(let docId, let language) = read else {
            return XCTFail("premise: a piece read in Serbian is .pieceInLanguage, got \(read)")
        }
        let items = ResolveEditionItems.items(language: language, isSource: false, docIds: [docId],
                                              read: edition, bookLevel: false)
        XCTAssertEqual(items.map(\.id), ["change:sr/doc-a#4/d1", "glossary:sr/doc-a#4/\u{00AB}fog\u{00BB}\u{2192}\u{00AB}fog-sr\u{00BB}"],
                       "its own round's change and term — no design proposal, no compile problem")
        XCTAssertEqual(ResolveEditionItems.items(language: "sr", isSource: false, docIds: ["doc-a"],
                                                 read: edition).count, 4,
                       "control: the edition's list holds the book's two as well")

        // The list groups as a piece: a question and a change on one
        // paragraph together, the term under the whole piece.
        let groups = ResolveGrouping.groups(
            ResolveSnapshot(items: snapshot.items + items, sequences: snapshot.sequences,
                            paragraphText: snapshot.paragraphText, unreadableDocIds: []),
            scope: read, structure: structure, sceneIndex: nil, sceneTitles: [], figureNames: [:],
            book: PieceNoun.Book(type: .novel))
        XCTAssertEqual(groups.map(\.key), [.wholePiece(docId: "doc-a"),
                                            .paragraph(docId: "doc-a", paragraphId: "aa11")])
        XCTAssertEqual(groups.last?.items.map(\.id),
                       ["note:doc-a/q-sr", "note:doc-a/q-SR-case", "change:sr/doc-a#4/d1"])
    }

    /// The live splice keeps a piece read in a language to its language too.
    func test_theOpenPiecesLiveNotesKeepToTheLanguage() {
        let live = ResolveLivePiece(
            notes: [note("q-sr", on: "doc-a", language: "sr").annotation,
                    note("q-es", on: "doc-a", language: "es").annotation,
                    note("c", on: "doc-a", language: nil, kind: .comment).annotation],
            todos: [WriterTask(id: "t", kind: .paneCreated, anchor: TaskAnchor(docId: "doc-a", paragraphId: nil),
                               body: "t", status: .open, priority: 0, parentTaskId: nil,
                               createdAt: t, createdBySession: nil)],
            sequence: ["aa11"], paragraphs: ["aa11": "Live."])
        let spliced = ResolvePane.splicing(.empty, scope: .pieceInLanguage(docId: "doc-a", language: "sr"),
                                           live: ["doc-a": live])
        XCTAssertEqual(spliced.items.map(\.id), ["note:doc-a/q-sr"])
        XCTAssertEqual(spliced.paragraphText, ["aa11": "Live."])
    }

    /// **A screenplay read in a language groups by scene, as its source
    /// does** (shell p5 Task 5): the window's script is the source's (a
    /// translated surface posts none), and its scenes place the language's
    /// items over the source sequence — the slugline titles the group.
    func test_aScreenplayReadInALanguageGroupsBySceneAsItsSourceDoes() {
        let scripts = [StructureItem(id: "doc-s", title: "Script", type: .document, path: "script.fountain")]
        let script = FountainTokenizer().parse("A cold open.\n\nINT. KITCHEN - DAY\n\nShe pours.")
        let read = ResolveScope.pieceInLanguage(docId: "doc-s", language: "sr")
        let source = ResolveScope.piece(docId: "doc-s", includesBookLevel: false)
        let held = ResolvePane.script(for: read, structure: scripts, openDocId: "doc-s",
                                      script: WindowScript(docId: "doc-s", script: script))
        XCTAssertNotNil(held, "the open script read in Serbian groups by scene")
        XCTAssertTrue(ResolvePane.groupsByScene(source, structure: scripts, openDocId: "doc-s"),
                      "control: its source scope does")
        XCTAssertFalse(ResolvePane.groupsByScene(.pieceInLanguage(docId: "doc-a", language: "sr"),
                                                 structure: structure, openDocId: "doc-a"),
                       "a chapter read in a language has no scenes")

        let snapshot = ResolveSnapshot(
            items: [.note(note("q-sr", on: "doc-s", language: "sr", paragraphId: "cc33"))],
            sequences: ["doc-s": ["aa11", "bb22", "cc33"]],
            paragraphText: ["aa11": "A cold open.", "bb22": "INT. KITCHEN - DAY", "cc33": "She pours."],
            unreadableDocIds: [])
        let scenes = ResolvePane.scenes(snapshot, scope: read, groupsByScene: held != nil, windowScript: held)
        XCTAssertEqual(scenes.index, ["bb22": 0, "cc33": 0])
        XCTAssertEqual(scenes.index, ResolvePane.scenes(snapshot, scope: source, groupsByScene: true,
                                                        windowScript: held).index,
                       "the same scenes as its source")
        let groups = ResolveGrouping.groups(snapshot, scope: read, structure: scripts,
                                            sceneIndex: scenes.index, sceneTitles: scenes.titles,
                                            figureNames: [:], book: PieceNoun.Book(type: .screenplay))
        XCTAssertEqual(groups.map(\.key), [.scene(docId: "doc-s", headingParagraphId: "bb22")])
        XCTAssertEqual(groups.map(\.title), ["INT. KITCHEN - DAY"])
    }

    /// **A piece is grouped by its own scenes, never the window's last
    /// parse** (shell p5 Task 5 fix round 1, I1): a Collection's script A
    /// was open in Source and posted its parse; script B opened straight into
    /// Serbian posts none, so the window still holds A's. B's notes go under
    /// B's sluglines — read in Serbian and in Source alike.
    func test_aPieceIsGroupedByItsOwnScenesNotTheWindowsLastParse() {
        let windowHoldsA = FountainTokenizer().parse(
            "EXT. HARBOUR - NIGHT\n\nRain.\n\nINT. LIGHTHOUSE - NIGHT\n\nA lamp.\n\nINT. CELLAR - DAY\n\nDust.")
        let scriptsAB = [StructureItem(id: "doc-a", title: "A", type: .document, path: "a.fountain"),
                         StructureItem(id: "doc-b", title: "B", type: .document, path: "b.fountain")]
        let snapshot = ResolveSnapshot(
            items: [.note(note("q-b", on: "doc-b", language: "sr", paragraphId: "dd44"))],
            sequences: ["doc-b": ["aa11", "bb22", "cc33", "dd44"]],
            paragraphText: ["aa11": "INT. KITCHEN - DAY", "bb22": "She pours.",
                            "cc33": "EXT. GARDEN - DUSK", "dd44": "He waits."],
            unreadableDocIds: [])
        for scope in [ResolveScope.pieceInLanguage(docId: "doc-b", language: "sr"),
                      .piece(docId: "doc-b", includesBookLevel: false)] {
            // The window holds A's parse; it is a refresh trigger, never grouped by.
            let held = ResolvePane.script(for: scope, structure: scriptsAB, openDocId: "doc-b",
                                          script: WindowScript(docId: "doc-a", script: windowHoldsA))
            XCTAssertNotNil(held, "premise: \(scope)")
            let scenes = ResolvePane.scenes(
                snapshot, scope: scope,
                groupsByScene: ResolvePane.groupsByScene(scope, structure: scriptsAB, openDocId: "doc-b"),
                windowScript: held)
            XCTAssertEqual(scenes.titles, ["INT. KITCHEN - DAY", "EXT. GARDEN - DUSK"], "\(scope)")
            XCTAssertEqual(scenes.index, ["aa11": 0, "bb22": 0, "cc33": 1, "dd44": 1], "\(scope)")
            let groups = ResolveGrouping.groups(snapshot, scope: scope, structure: scriptsAB,
                                                sceneIndex: scenes.index, sceneTitles: scenes.titles,
                                                figureNames: [:], book: PieceNoun.Book(type: .collection))
            XCTAssertEqual(groups.map(\.key), [.scene(docId: "doc-b", headingParagraphId: "cc33")], "\(scope)")
            XCTAssertEqual(groups.map(\.title), ["EXT. GARDEN - DUSK"], "\(scope)")
        }
    }

    /// **Typing in the open screenplay costs no second parse** (shell p5a
    /// closing round B): each ~350 ms edge posts the editor's parse, naming
    /// its piece, and both the list and the tree's presence read take their
    /// scenes from it — zero parses of their own. The control: the same piece
    /// read in a language parses once per text, the list and presence
    /// sharing that one parse.
    func test_typingInTheOpenScreenplayCostsNoSecondParse() {
        let scripts = [StructureItem(id: "doc-s", title: "Script", type: .document, path: "script.fountain")]
        let list = ResolveScope.piece(docId: "doc-s", includesBookLevel: false)
        let presence = ResolveScope.piece(docId: "doc-s", includesBookLevel: true)
        let parses = SceneParseMemo.parseCount
        for typed in ["She pours.", "She pours tea.", "She pours tea.\n\nEXT. GARDEN - DUSK"] {
            let paragraphs = ["aa11": "INT. KITCHEN - DAY", "bb22": typed]
            let snapshot = ResolveSnapshot(items: [], sequences: ["doc-s": ["aa11", "bb22"]],
                                           paragraphText: paragraphs, unreadableDocIds: [])
            let edge = WindowScript(docId: "doc-s",
                                    script: FountainTokenizer().parse("INT. KITCHEN - DAY\n\n" + typed))
            let listed = ResolvePane.scenes(
                snapshot, scope: list,
                groupsByScene: ResolvePane.groupsByScene(list, structure: scripts, openDocId: "doc-s"),
                windowScript: WindowScript.live(edge, openDocId: "doc-s"))
            // The window hands the presence read the editor's live parse.
            let marked = ResolvePresence.sceneIndex(
                snapshot, scope: presence, structure: scripts,
                windowScript: ResolvePane.script(for: presence, structure: scripts, openDocId: nil,
                                                 script: WindowScript.live(edge, openDocId: "doc-s")))
            XCTAssertEqual(listed.titles.first, "INT. KITCHEN - DAY")
            XCTAssertEqual(listed.index, marked)
        }
        XCTAssertEqual(SceneParseMemo.parseCount, parses, "typing parsed nothing beyond the editor's own parse")

        // The control: read in Serbian, the piece is parsed — once per text,
        // shared by the list and presence.
        let snapshot = ResolveSnapshot(items: [], sequences: ["doc-s": ["aa11", "bb22"]],
                                       paragraphText: ["aa11": "INT. KITCHEN - DAY", "bb22": "Once."],
                                       unreadableDocIds: [])
        let read = ResolveScope.pieceInLanguage(docId: "doc-s", language: "sr")
        let edge = WindowScript(docId: "doc-s", script: FountainTokenizer().parse("INT. KITCHEN - DAY\n\nOnce."))
        for _ in 0..<2 {
            _ = ResolvePane.scenes(snapshot, scope: read, groupsByScene: true, windowScript: edge)
        }
        XCTAssertEqual(SceneParseMemo.parseCount, parses + 1, "a piece read in a language parses its source once")
    }

    /// **Scenes follow the text, not a parse made at open** (closing round
    /// B2, M1): a one-script project with no editor open holds the op-log
    /// parse made when the window opened; another Mac's edit then adds a
    /// scene. The Book's presence and the list group by the new text. The
    /// control: the editor's live parse of the open script is reused.
    func test_scenesFollowTheTextWhenNoEditorIsOpen() {
        let scripts = [StructureItem(id: "doc-s", title: "Script", type: .document, path: "script.fountain")]
        let atOpen = WindowScript(docId: "doc-s",
                                  script: FountainTokenizer().parse("INT. KITCHEN - DAY\n\nShe pours."))
        let arrived = ResolveSnapshot(
            items: [], sequences: ["doc-s": ["aa11", "bb22", "cc33", "dd44"]],
            paragraphText: ["aa11": "INT. KITCHEN - DAY", "bb22": "She pours.",
                            "cc33": "EXT. GARDEN - DUSK", "dd44": "He waits."],
            unreadableDocIds: [])
        let book = ResolveScope.piece(docId: "doc-s", includesBookLevel: true)
        let noEditor = WindowScript.live(atOpen, openDocId: nil)
        XCTAssertNil(noEditor, "no editor open: the parse made at open is not live")
        XCTAssertEqual(ResolvePresence.sceneIndex(arrived, scope: book, structure: scripts, windowScript: noEditor),
                       ["aa11": 0, "bb22": 0, "cc33": 1, "dd44": 1], "the presence follows the arrived scene")
        let list = ResolvePane.scenes(arrived, scope: .piece(docId: "doc-s", includesBookLevel: false),
                                      groupsByScene: true, windowScript: noEditor)
        XCTAssertEqual(list.titles, ["INT. KITCHEN - DAY", "EXT. GARDEN - DUSK"], "and so does the list")

        XCTAssertNotNil(WindowScript.live(atOpen, openDocId: "doc-s"), "control: the open editor's parse is live")
        XCTAssertNil(WindowScript.live(atOpen, openDocId: "doc-other"), "another piece open: not live")
    }

    /// **An edition open with a chapter faced is that chapter in that
    /// language** — the design's "the faces follow the piece".
    func test_anEditionWithAChapterFacedIsThatChapterInThatLanguage() {
        XCTAssertEqual(scope(WindowSubject(open: .edition(language: "sr"), faces: .item("doc-b")), switched: nil),
                       .pieceInLanguage(docId: "doc-b", language: "sr"))
        XCTAssertEqual(scope(WindowSubject(open: .edition(language: "sr"), faces: .edition(language: "sr")),
                             switched: nil),
                       .edition(language: "sr", isSource: false, docIds: ["doc-a", "doc-b"]),
                       "control: the edition faced is the edition")
        XCTAssertEqual(scope(WindowSubject(open: .edition(language: "en"), faces: .item("doc-b")), switched: nil),
                       .piece(docId: "doc-b", includesBookLevel: false),
                       "the Source edition reads the piece in its source")
        XCTAssertEqual(scope(WindowSubject(open: .item("doc-a"), faces: .item("doc-a")), switched: nil),
                       .piece(docId: "doc-a", includesBookLevel: false), "read in Source: the source's list")
        XCTAssertEqual(ResolveScope.pieceInLanguage(docId: "doc-a", language: "sr").translationLanguage, "sr")
        XCTAssertEqual(ResolveHead.shape(.pieceInLanguage(docId: "doc-a", language: "sr")),
                       .pieceInLanguage(docId: "doc-a", language: "sr"))
        XCTAssertEqual(BriefScope.of(.item("doc-a"), structure: structure, projectType: .novel),
                       .piece(docId: "doc-a"), "Brief stays the piece's")
    }

    /// ⌘⌥L lands on Questions over a piece read in a language; ⌘⌥A/D/T,
    /// whose chips such a list never has, leave the writer's filter as it was.
    func test_questionsKeyLandsOnQuestionsAndTheOthersAreInert() {
        let chips = ResolveFilter.chips(
            [.note(note("q", on: "doc-a", language: "sr")),
             .translationChange(docId: "doc-a", language: "sr", round: 1, departure("d"))],
            passes: [], localName: "Denver")
        XCTAssertEqual(chips, [.questions, .changes])
        let questions = ResolvePane.apply(.filter(.questions), groups: [], sceneIndex: nil, chips: chips, activePassId: nil,
                                          dense: false, selection: [.changes], choices: [:])
        XCTAssertEqual(questions.selection, [.questions])
        for key in [ResolveKeyFilter.rounds, .checks, .mine] {
            let outcome = ResolvePane.apply(.filter(key), groups: [], sceneIndex: nil, chips: chips, activePassId: nil,
                                            dense: false, selection: [.changes], choices: [:])
            XCTAssertEqual(outcome.selection, [.changes], "\(key) leaves the filter as it was")
        }
        // Over a piece read in a language the key's filter is handed over —
        // the review that dropped it is gone.
        let info: [AnyHashable: Any] = [MaughamEvent.positionKey: RightColumnPosition.resolve.rawValue,
                                        MaughamEvent.resolveFilterKey: ResolveKeyFilter.questions.rawValue]
        XCTAssertEqual(ProjectWindow.positionAsk(in: info, shows: .resolve).request, .filter(.questions))
    }

    // MARK: - The head's round

    /// **The head is that chapter's own latest round** — after a whole-book
    /// run and then a second run on one chapter (Review Focus 1), and with
    /// another chapter's newer round in the ledger: one decode answers the
    /// chapter's finished round, its newest of any outcome and its trend.
    func test_theHeadIsThatChaptersOwnLatestRound() throws {
        let store = TranslationRoundStore(projectURL: try makeProject())
        for (number, docId) in ["doc-a", "doc-b", "doc-c"].enumerated() {
            try store.append(round(number + 1, docId: docId, summary: "Book run on \(docId)."))
        }
        try store.append(round(4, docId: "doc-b", summary: "Second run on two."))
        try store.append(round(5, docId: "doc-c", summary: "Another chapter, newer."))
        // Age the whole-book run out of the ring.
        for number in 6...16 { try store.append(round(number, docId: "doc-z\(number)")) }

        let a = store.pieceRounds(language: "sr", docId: "doc-a")
        XCTAssertEqual(a.latestFinished?.number, 1, "the first run's letter is still reachable")
        let b = store.pieceRounds(language: "sr", docId: "doc-b")
        XCTAssertEqual(b.latestFinished?.number, 4)
        XCTAssertEqual(b.newest?.number, 4)

        var read = ResolveEditionItems.Read(language: "sr")
        read.rounds = b.latestFinished.map { ["doc-b": $0] } ?? [:]
        read.newestRound = b.newest
        let head = ResolvePieceInLanguage.headRounds(read, docId: "doc-b", running: false, now: t)
        XCTAssertEqual(head.letter?.number, 4)
        XCTAssertEqual(head.letter.flatMap(ResolveEditionItems.letter(of:)), "Second run on two.")
        XCTAssertNil(head.stopped)

        // A cancelled run on two now: said above the finished letter, which
        // is then the earlier one.
        try store.append(round(17, docId: "doc-b", cancelled: true))
        let stopped = store.pieceRounds(language: "sr", docId: "doc-b")
        XCTAssertEqual(stopped.latestFinished?.number, 4, "a cancelled round is not finished")
        read.newestRound = stopped.newest
        let said = ResolvePieceInLanguage.headRounds(read, docId: "doc-b", running: false, now: t)
        XCTAssertEqual(said.stopped?.number, 17)
        XCTAssertTrue(said.letterIsEarlier)
        XCTAssertNil(ResolvePieceInLanguage.headRounds(read, docId: "doc-b", running: true, now: t).stopped,
                     "while a round runs, its own line speaks")
        // Another chapter's newest is never this chapter's.
        read.newestRound = round(18, docId: "doc-c", failed: true)
        XCTAssertNil(ResolvePieceInLanguage.headRounds(read, docId: "doc-b", running: false, now: t).stopped)
        XCTAssertEqual(store.pieceRounds(language: "sr", docId: "doc-b").trend.count, 1,
                       "the trend is this piece's rounds still in the ring")
    }

    func test_theHeadsLinesSayWhatIsTrue() {
        XCTAssertEqual(ResolvePieceInLanguage.noLetterLine(translator: "Kiš", language: "sr", noun: "chapter",
                                                           hasRounds: false),
                       "Kiš has not run a round on this chapter in \(LanguageName.title("sr")) yet.")
        XCTAssertEqual(ResolvePieceInLanguage.noLetterLine(translator: "Kiš", language: "sr", noun: "chapter",
                                                           hasRounds: true),
                       "Kiš wrote no letter on this chapter\u{2019}s latest round.")
        let signed = ResolvePieceInLanguage.signature(translator: "Kiš", round: round(4, docId: "doc-a"))
        XCTAssertTrue(signed.hasPrefix("\u{2014} Kiš \u{00B7} round 4"), signed)
        XCTAssertEqual(ResolvePieceInLanguage.runScopeLine(noun: "chapter", language: "sr",
                                                           preflight: .words(1200)),
                       "Translates this chapter into \(LanguageName.title("sr")) \u{00B7} "
                       + (TranslationRunState.preflightLine(.words(1200)) ?? "") + ".")
    }

    // MARK: - The empty list

    /// **Never "nothing waits" while the questions are still being read**, and
    /// where the piece's SOURCE has something open — the dot its tree row
    /// carries — the empty list says so.
    func test_anEmptyListSaysWhatIsTrue() throws {
        let reading = ResolvePieceInLanguage.clearLine(language: "sr", noun: "chapter", hasRounds: true,
                                                       readingBook: true, sourceHasSomething: false)
        XCTAssertTrue(reading.hasPrefix("Still reading"), reading)
        let none = ResolvePieceInLanguage.clearLine(language: "sr", noun: "chapter", hasRounds: false,
                                                    readingBook: false, sourceHasSomething: false)
        XCTAssertTrue(none.hasPrefix("No round has run on this chapter"), none)
        let settled = ResolvePieceInLanguage.clearLine(language: "sr", noun: "chapter", hasRounds: true,
                                                       readingBook: false, sourceHasSomething: false)
        XCTAssertTrue(settled.contains("waits on you"), settled)
        XCTAssertFalse(settled.contains("Source"))
        let dotted = ResolvePieceInLanguage.clearLine(language: "sr", noun: "chapter", hasRounds: true,
                                                      readingBook: false, sourceHasSomething: true)
        XCTAssertTrue(dotted.hasSuffix(ResolvePieceInLanguage.sourceHasSomethingLine), dotted)
        // One predicate: the row's dot (`rowMark`) is what the pane asks.
        let pane = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/Resolve/ResolvePane.swift"))
            .joined(separator: " ")
        XCTAssertTrue(pane.contains("ResolvePresence.rowMark(.item(docId), in: $0) == .something"))
        XCTAssertEqual(ResolvePane.emptyState(scope: .pieceInLanguage(docId: "doc-a", language: "sr"),
                                              hasItems: false, hasVisible: false, offersColdStart: false,
                                              editionClear: dotted),
                       .editionClear(dotted))
        XCTAssertEqual(ResolvePane.emptyState(scope: .pieceInLanguage(docId: "doc-a", language: "sr"),
                                              hasItems: true, hasVisible: false, offersColdStart: false),
                       .filteredOut)
    }

    /// **Closing review M4**: Run's VoiceOver label names the piece by the
    /// project's own word, as the scope line beside it does.
    func test_runsLabelNamesThePieceByTheProjectsWord() {
        XCTAssertEqual(ResolvePieceInLanguage.runAccessibilityLabel(language: "sr", noun: .story),
                       "Translate This Story into " + LanguageName.labelled("sr"))
        // Voice Control: every run button's label begins with what it shows.
        XCTAssertTrue(TranslationRunState.runBookAccessibilityLabel(language: "sr")
                        .hasPrefix(TranslationRunState.runBookTitle))
        XCTAssertEqual(DesignRoundState.runAccessibilityLabel, DesignRoundState.runTitle)
    }

    // MARK: - The source's keys (closing review I2)

    /// **⌘⌥A, ⌘⌥D and ⌘⌥T over a chapter read in a language read it in
    /// Source first**: that language's list holds none of what they ask for.
    /// Every other ground lists them already; ⌘⌥L is the language's own.
    func test_theSourceKeysReadAChapterReadInALanguageInSourceFirst() throws {
        let grounds: [(String, ResolveScope, String?)] = [
            ("a Source chapter", .piece(docId: "doc-a", includesBookLevel: false), nil),
            ("a chapter read in a language", .pieceInLanguage(docId: "doc-a", language: "es"), "doc-a"),
            ("an edition", .edition(language: "es", isSource: false, docIds: ["doc-a"]), nil),
            ("the Book", .pieces(docIds: ["doc-a"], includesBookLevel: true), nil),
        ]
        for (ground, scope, readsFirst) in grounds {
            for key in [ResolveKeyFilter.rounds, .checks, .mine] {
                XCTAssertEqual(ResolvePieceInLanguage.readsSourceFirst(key, scope: scope), readsFirst,
                               "\(key) over \(ground)")
            }
            XCTAssertNil(ResolvePieceInLanguage.readsSourceFirst(.questions, scope: scope),
                         "Questions are the language's own, over \(ground)")
        }
        // The open piece switches in place; a chapter only faced opens.
        XCTAssertEqual(ResolvePieceInLanguage.sourceRead(docId: "doc-a", openDocId: "doc-a"), .switchHere)
        XCTAssertEqual(ResolvePieceInLanguage.sourceRead(docId: "doc-a", openDocId: nil), .open(docId: "doc-a"))
        XCTAssertEqual(ResolvePieceInLanguage.sourceRead(docId: "doc-a", openDocId: "doc-b"), .open(docId: "doc-a"))

        // The wiring: the key's receiver asks the rule over the scope the
        // list shows, BEFORE the position and the filter land; the empty
        // list's line is the same act.
        let window = SourceScan.codeLines(of: try SourceTree.declaration(
            named: "struct SessionAndNavigationModifier", under: "Maugham"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        let ask = try XCTUnwrap(window.range(of: "ResolvePieceInLanguage.readsSourceFirst(filter, scope: ResolveScope.of("))
        let read = try XCTUnwrap(window.range(of: "ResolvePieceInLanguage.readSource(docId: docId, openDocId: subject.open.itemID)"))
        let select = try XCTUnwrap(window.range(of: "ProjectWindow.selectPosition("))
        let filter = try XCTUnwrap(window.range(of: "let ask = ProjectWindow.positionAsk("))
        XCTAssertTrue(ask.lowerBound < read.lowerBound && read.lowerBound < select.lowerBound
                      && select.lowerBound < filter.lowerBound,
                      "Source is read before the column and the filter land")
        XCTAssertTrue(window.contains("subject.faces, readIn: readingLanguage, sourceLanguage: sourceLanguage,"))
        let pane = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/Resolve/ResolvePane.swift"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        XCTAssertTrue(pane.contains("Button(ResolvePieceInLanguage.readSourceTitle) { ResolvePieceInLanguage.readSource(docId: docId, openDocId: openDocId) }"),
                      "the empty list's line is a button that reads Source")
    }

    // MARK: - Run, on this piece

    /// **Run is hidden where the translator may not translate the piece**, and
    /// off the open piece (where the head says how instead).
    func test_runIsHiddenWhereTheTranslatorMayNot() {
        XCTAssertTrue(ResolvePieceInLanguage.offersRun(docId: "doc-a", isOpen: true, mayTranslate: { _ in true }))
        XCTAssertFalse(ResolvePieceInLanguage.offersRun(docId: "doc-a", isOpen: true, mayTranslate: { _ in false }),
                       "the translator may not: no Run")
        XCTAssertFalse(ResolvePieceInLanguage.offersRun(docId: "doc-a", isOpen: true,
                                                        mayTranslate: { $0 == "doc-b" }),
                       "another piece's permission is not this one's")
        XCTAssertFalse(ResolvePieceInLanguage.offersRun(docId: "doc-a", isOpen: false, mayTranslate: { _ in true }),
                       "not open: no Run")
        XCTAssertEqual(ResolvePieceInLanguage.openToRunLine(noun: "chapter"),
                       "Open this chapter to translate it")
    }

    /// Run's refusals in order, then the one start over this piece; the
    /// cast sheet's Confirm runs the piece it was asked over.
    func test_runDecidesThenStartsThisPiece() async {
        var started: [(String, String)] = []
        var verbs = PieceInLanguageHeadVerbs()
        verbs.startRun = { language, docId in
            started.append((language, docId))
            return .init(notice: nil)
        }
        let busy = await ResolvePieceInLanguage.run(language: "sr", docId: "doc-a",
                                                    session: .busy(language: "es"), verbs: verbs)
        XCTAssertEqual(busy.notice, TranslationRunState.busyReason(language: "es"))
        let unusable = await ResolvePieceInLanguage.run(language: "SR", docId: "doc-a", session: .free,
                                                        verbs: verbs)
        XCTAssertEqual(unusable.notice, TranslationRunState.unusableTag(language: "SR"))
        XCTAssertTrue(started.isEmpty, "a refusal starts nothing")
        _ = await ResolvePieceInLanguage.run(language: "sr", docId: "doc-a", session: .free, verbs: verbs)
        XCTAssertEqual(started.map { "\($0.0)/\($0.1)" }, ["sr/doc-a"])
    }

    // MARK: - Whose run it is (fix round 1, I2 + M10)

    private func running(_ docId: String, _ language: String = "es",
                         book: TranslationPipeline.BookProgress? = nil) -> TranslationPipeline.Status {
        .running(docId: docId, language: language, leg: .reread, book: book)
    }

    /// **A chapter's head speaks only for its own run.** Another chapter's
    /// round — or this chapter's in another language — is said quietly, with
    /// no Cancel and no Run; this chapter's, or a book run still to reach it,
    /// is the head's.
    func test_aRoundOnAnotherChapterIsNotThisChaptersRun() {
        let other = ResolvePieceInLanguage.pieceRun(status: running("doc-7"), queued: [],
                                                    docId: "doc-3", language: "es")
        XCTAssertEqual(other, .elsewhere(docId: "doc-7", language: "es", book: nil))
        XCTAssertEqual(ResolvePieceInLanguage.pieceRun(status: running("doc-3", "fr"), queued: [],
                                                       docId: "doc-3", language: "es"),
                       .elsewhere(docId: "doc-3", language: "fr", book: nil),
                       "this chapter in another language is not this list's run")
        XCTAssertEqual(ResolvePieceInLanguage.pieceRun(status: running("doc-3"), queued: [],
                                                       docId: "doc-3", language: "ES"), .this)
        XCTAssertEqual(ResolvePieceInLanguage.pieceRun(status: .idle, queued: [], docId: "doc-3", language: "es"),
                       .none)
        let book = TranslationPipeline.BookProgress(position: 2, count: 12)
        XCTAssertEqual(ResolvePieceInLanguage.pieceRun(status: running("doc-2", book: book),
                                                       queued: ["doc-3", "doc-4"],
                                                       docId: "doc-3", language: "es"), .this,
                       "a book run still to reach this chapter is its run")
        XCTAssertEqual(ResolvePieceInLanguage.pieceRun(status: running("doc-2", book: book),
                                                       queued: ["doc-4"], docId: "doc-1", language: "es"),
                       .elsewhere(docId: "doc-2", language: "es", book: book),
                       "a book run that has passed this chapter, or leaves it out, is not")
        let line = ResolvePieceInLanguage.elsewhereLine(other, noun: "chapter",
                                                        titleOf: { $0 == "doc-7" ? "Chapter Seven" : nil })
        XCTAssertEqual(line, "Translating \u{201C}Chapter Seven\u{201D} into \(LanguageName.title("es"))\u{2026}")
        XCTAssertNil(ResolvePieceInLanguage.elsewhereLine(.this, noun: "chapter", titleOf: { _ in nil }))
        XCTAssertEqual(ResolvePieceInLanguage.elsewhereLine(
            .elsewhere(docId: "doc-2", language: "es", book: nil), noun: "story", titleOf: { _ in nil }),
                       "Translating another story into \(LanguageName.title("es"))\u{2026}")
        XCTAssertTrue(ResolvePieceInLanguage.elsewhereLine(
            .elsewhere(docId: "doc-2", language: "es", book: book), noun: "chapter", titleOf: { _ in "Two" })?
            .contains("2 of 12") ?? false)
    }

    /// **Cancel reaches only its own run**: the head hands `resolve` the
    /// pipeline's status only for this chapter's run, so another chapter's
    /// round draws no Cancel and no leg line here.
    func test_cancelReachesOnlyItsOwnRun() {
        func state(_ status: TranslationPipeline.Status, queued: [String] = []) -> TranslationRunState {
            let relation = ResolvePieceInLanguage.pieceRun(status: status, queued: queued,
                                                           docId: "doc-3", language: "es")
            return TranslationRunState.resolve(noun: .chapter,
                language: "es", target: .ready(docId: "doc-3", title: "Three"),
                session: TranslationRunSession.read(runState: .idle, isRunning: false, pipeline: status),
                runState: .idle, lastRun: nil,
                pipeline: ResolvePieceInLanguage.pipelineStatus(status, relation: relation))
        }
        XCTAssertFalse(state(running("doc-7")).isRunning, "another chapter's round: no Cancel, no leg")
        XCTAssertNil(state(running("doc-7")).statusLine)
        XCTAssertTrue(state(running("doc-3")).isRunning, "this chapter's round: Cancel")
        XCTAssertTrue(state(running("doc-2", book: .init(position: 1, count: 3)), queued: ["doc-3"]).isRunning)
        XCTAssertFalse(state(running("doc-2", book: .init(position: 1, count: 3)), queued: ["doc-4"]).isRunning)
        XCTAssertFalse(ResolvePieceInLanguage.offersRun(docId: "doc-3", isOpen: true, mayTranslate: { _ in true },
                                                        relation: .elsewhere(docId: "doc-7", language: "es", book: nil)),
                       "Run is not offered while the one pipeline runs another chapter")
        // The stopped line hides only while THIS chapter runs.
        var read = ResolveEditionItems.Read(language: "es")
        read.newestRound = round(9, docId: "doc-3", language: "es", cancelled: true)
        XCTAssertNotNil(ResolvePieceInLanguage.headRounds(
            read, docId: "doc-3",
            running: ResolvePieceInLanguage.pieceRun(status: running("doc-9", "fr"), queued: [],
                                                     docId: "doc-3", language: "es") == .this,
            now: t).stopped, "a French round elsewhere does not hide why this one stopped")
    }

    /// The edition's head names the chapter of a one-chapter round; a book
    /// run's line already counts.
    func test_theEditionsLegLineNamesAOneChapterRound() {
        XCTAssertEqual(ResolveEditionItems.runningLine("Re-reading", pipeline: running("doc-7"),
                                                       titleOf: { _ in "Seven" }),
                       "\u{201C}Seven\u{201D} \u{00B7} Re-reading")
        XCTAssertEqual(ResolveEditionItems.runningLine("Re-reading (2 of 3)",
                                                       pipeline: running("doc-7", book: .init(position: 2, count: 3)),
                                                       titleOf: { _ in "Seven" }), "Re-reading (2 of 3)")
    }

    // MARK: - The open-the-piece line (fix round 1, I1 + M12)

    func test_offThePieceTheHeadSaysWhyAndOpensIt() {
        XCTAssertEqual(ResolvePieceInLanguage.openSlot(isOpen: false, isOpening: false, hasItemsToAnswer: true,
                                                       noun: "chapter"),
                       .open("Open this chapter to answer its questions"))
        XCTAssertEqual(ResolvePieceInLanguage.openSlot(isOpen: false, isOpening: false, hasItemsToAnswer: false,
                                                       noun: "chapter"),
                       .open("Open this chapter to translate it"))
        XCTAssertEqual(ResolvePieceInLanguage.openSlot(isOpen: false, isOpening: true, hasItemsToAnswer: true,
                                                       noun: "chapter"),
                       .opening, "never 'open' what is already opening")
        XCTAssertEqual(ResolvePieceInLanguage.openSlot(isOpen: true, isOpening: false, hasItemsToAnswer: true,
                                                       noun: "chapter"), .run)
        XCTAssertTrue(ResolveHead.hasItemsToAnswer([.note(note("q", on: "doc-a", language: "es"))], docId: "doc-a"))
        XCTAssertFalse(ResolveHead.hasItemsToAnswer(
            [.translationChange(docId: "doc-a", language: "es", round: 1, departure("d"))], docId: "doc-a"),
            "a change acts without the piece open")
    }

    // MARK: - The cost under Run (fix round 1, M1)

    func test_theCostIsShownOnlyForThePieceItWasTakenFor() {
        let taken = ResolvePieceInLanguage.Cost(docId: "doc-7", language: "es", answer: .words(900))
        XCTAssertEqual(taken.answer(docId: "doc-7", language: "es"), .words(900))
        XCTAssertNil(taken.answer(docId: "doc-3", language: "es"), "another chapter: nothing, never a stale figure")
        XCTAssertNil(taken.answer(docId: "doc-7", language: "fr"))
    }

    // MARK: - Clear asks and decides over the store (fix round 1, M2 + M3)

    func test_clearDecidesOverWhatTheStoreHoldsAtThePress() {
        let shown: [ResolvePieceInLanguage.LeftOver] = [.init(id: "zz11", staleText: "A"),
                                                         .init(id: "zz22", staleText: "B")]
        XCTAssertEqual(ResolvePieceInLanguage.clearDecision(shown: shown, now: shown + [.init(id: "zz33", staleText: "C")]),
                       .clear(["zz11", "zz22"]), "exactly what was shown, never a newer one")
        XCTAssertEqual(ResolvePieceInLanguage.clearDecision(shown: shown, now: [.init(id: "zz11", staleText: "A")]),
                       .refuse(ResolvePieceInLanguage.changedSinceShownLine),
                       "a paragraph came back: refused, nothing cleared")
        XCTAssertEqual(ResolvePieceInLanguage.clearDecision(
            shown: shown, now: [.init(id: "zz11", staleText: "A"), .init(id: "zz22", staleText: "B2")]),
                       .refuse(ResolvePieceInLanguage.changedSinceShownLine), "a text changed: refused")
        XCTAssertEqual(ResolvePieceInLanguage.clearConfirmTitle(count: 3),
                       "Clear 3 left-over translations? Their paragraphs no longer exist.")
        XCTAssertEqual(ResolvePieceInLanguage.clearConfirmTitle(count: 1),
                       "Clear 1 left-over translation? Its paragraph no longer exists.")
        XCTAssertTrue(ResolvePieceInLanguage.leftOversStartShown(count: 3))
        XCTAssertFalse(ResolvePieceInLanguage.leftOversStartShown(count: 4))
    }

    // MARK: - Left over from deleted paragraphs

    /// **Left-over rows act only on the open piece**, where the author may
    /// translate it; the door refuses a press that arrives anyway
    /// (`PostureSurfaceTests.test_anOrphanPurgeIsRefusedWhereTheAuthorMayNotTranslate`).
    func test_leftOverRowsActOnlyOnTheOpenPiece() {
        let author = Posture(.unrestricted)
        let reviewer = Posture(LocalWritePermit(permit: .reviewer, actor: .author,
                                                documentClass: .piece("doc-a")))
        XCTAssertTrue(ResolvePieceInLanguage.offersClear(isOpen: true, authorPosture: author))
        XCTAssertFalse(ResolvePieceInLanguage.offersClear(isOpen: false, authorPosture: author),
                       "not open: no Clear")
        XCTAssertFalse(ResolvePieceInLanguage.offersClear(isOpen: true, authorPosture: reviewer),
                       "may not translate: no Clear")
    }

    func test_whatTheTranslationLacksAndLeavesOver() {
        let translation = ResolvePieceInLanguage.translation(
            docId: "doc-a", language: "sr",
            statuses: [("aa11", .fresh), ("bb22", .stale), ("cc33", .missing), ("dd44", .stale)],
            orphans: [TranslationRecord(paragraphId: "zzzz", language: "sr", text: "Siroče", sourceHash: "x"),
                      TranslationRecord(paragraphId: "yyyy", language: "sr", text: nil, sourceHash: "x")])
        XCTAssertEqual(translation.outOfDate, ["bb22", "dd44"])
        XCTAssertEqual(translation.untranslated, ["cc33"])
        XCTAssertEqual(translation.leftOvers, [.init(id: "zzzz", staleText: "Siroče")],
                       "a tombstone is no left-over (the derive's backstop)")
        XCTAssertEqual(ResolvePieceInLanguage.freshnessLine(translation),
                       "2 paragraphs out of date \u{00B7} 1 paragraph not translated yet")
        XCTAssertNil(ResolvePieceInLanguage.freshnessLine(
            .init(docId: "doc-a", language: "sr", paragraphCount: 3)), "nothing lacking: no line")
        let untouched = ResolvePieceInLanguage.translation(
            docId: "doc-a", language: "sr", statuses: [("aa11", .missing), ("bb22", .missing)], orphans: [])
        XCTAssertEqual(ResolvePieceInLanguage.freshnessLine(untouched), "none of its 2 paragraphs translated yet")
        XCTAssertEqual(ResolvePieceInLanguage.leftOverLine(count: 1),
                       "1 translation left over from a deleted paragraph")
    }

    /// **Clear writes one tombstone per id, in one batch, in the writer's own
    /// file** (moved from the review pane's purge).
    func test_clearWritesOneTombstonePerIdInOneBatch() async throws {
        let dir = try makeProject()
        let identities = LocalIdentities.current
        try await TranslationStore.appendBatch(
            ["zzzz", "yyyy"].map {
                TranslationRecord(paragraphId: $0, language: "es", text: "Huérfano", sourceHash: "x")
            },
            forDocId: "doc1", language: "es", identity: identities.translator,
            identities: identities, in: dir)
        try await ResolvePieceInLanguage.clear(["zzzz", "yyyy"], docId: "doc1", language: "es",
                                               identities: identities, projectURL: dir)
        let url = try TranslationStore.fileURL(forDocId: "doc1", language: "es",
                                               deviceSlug: identities.author.slug, in: dir)
        let lines = try Data(contentsOf: url)
            .split(separator: 0x0A, omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }.map { Data($0) }
            .filter { !OpLogChain.isSealLine($0) }
        XCTAssertEqual(lines.count, 2, "one tombstone line per id, in the writer's own file")
        let loaded = try TranslationStore.loadMerged(forDocId: "doc1", language: "es", in: dir)
        XCTAssertEqual(loaded.suffix(2).filter { $0.text == nil }.count, 2)
        let derived = TranslationDeriver.derive(records: loaded, sequence: ["aaaa"],
                                                paragraphs: ["aaaa": "One"], language: "es")
        XCTAssertTrue(derived.orphans.isEmpty, "a cleared left-over does not come back")
    }

    // MARK: - Moved from the review pane's logic

    func test_openQueriesKeepTheLanguagesOpenQueriesOnly() {
        let anns = [note("1", on: "d", language: "fr").annotation,
                    note("2", on: "d", language: "es").annotation,
                    note("3", on: "d", language: "fr", kind: .comment).annotation,
                    note("4", on: "d", language: "fr", status: .accepted).annotation,
                    note("5", on: "d", language: "FR").annotation,
                    note("6", on: "d", language: nil).annotation]
        XCTAssertEqual(ResolveEditionItems.openQueries(anns, language: "fr").map(\.id), ["1", "5"])
        XCTAssertTrue(ResolveEditionItems.openQueries(anns, language: nil).isEmpty,
                      "no language: nothing, never a nil == nil match")
    }

    func test_aSpotChecksAnswerBelongsOnlyUnderTheParagraphItWasAskedAbout() {
        XCTAssertTrue(PieceInLanguageCaretSection.answerStillBelongs(askedAbout: "aaaa", selected: "aaaa"))
        XCTAssertFalse(PieceInLanguageCaretSection.answerStillBelongs(askedAbout: "aaaa", selected: "bbbb"))
        XCTAssertFalse(PieceInLanguageCaretSection.answerStillBelongs(askedAbout: "aaaa", selected: nil))
    }

    func test_twoDeparturesOnOneParagraphAreTwoRows() {
        let report = CollatorReport(overall: "Close.", departures: [
            .init(paragraphId: "aa11", verdict: .drifted, kind: .mistranslation, note: "n1", gloss: "g1"),
            .init(paragraphId: "aa11", verdict: .drifted, kind: .inconsistency, note: "n2", gloss: "g2")])
        let rows = PieceInLanguageCaretSection.departureRows(report, dismissed: ["aa11-1"], source: { _ in "S" })
        XCTAssertEqual(rows.map(\.id), ["aa11-0", "aa11-1"])
        XCTAssertEqual(rows.map(\.isDismissed), [false, true])
        XCTAssertNil(rows.first?.after, "a spot-check has no rewrite to show")
    }

    // MARK: - Earlier letters (a piece's ordinary head)

    private func letter(_ about: String) -> Letter {
        Letter(about: about, oneThing: "One thing.", working: [], habits: [], questions: [],
               scenes: nil, scenePosition: nil)
    }

    private func run(_ id: String, passId: String?, round: Int?, letter: Letter?,
                     kind: RunKind = .round) -> CompilerRun {
        CompilerRun(id: id, at: t, model: "m", lastOpId: nil, deltaSummary: "", intentSnapshot: nil,
                    passId: passId, round: round, kind: kind, readerName: nil, letter: letter)
    }

    private let passes = [ReviewPass(id: "line", name: "Line", editorName: "Lish"),
                          ReviewPass(id: "structure", name: "Structure", editorName: "Perkins")]

    func test_earlierLettersListsEachPassesLatest() {
        let perkins = run("r-p", passId: "structure", round: 2, letter: letter("Structure."))
        let lish = run("r-l", passId: "line", round: 5, letter: letter("Line."))
        let retired = run("r-x", passId: "gone", round: 1, letter: letter("Retired."))
        let mute = run("r-m", passId: "line", round: 6, letter: nil)
        let earlier = ResolveHead.earlierLetters([lish, perkins, retired, mute], shown: lish, passes: passes)
        XCTAssertEqual(earlier.map(\.id), ["r-p"],
                       "each other pass's latest that says something, of a pass still listed")
        XCTAssertEqual(ResolveHead.earlierLetterTitle(perkins, passes: passes), "Perkins \u{00B7} round 2")
        // Choosing one draws it; a choice no longer listed falls back.
        XCTAssertEqual(HeadLetterArea.shown(latest: lish, earlier: earlier, chosen: "r-p")?.id, "r-p")
        XCTAssertEqual(HeadLetterArea.shown(latest: lish, earlier: earlier, chosen: "r-gone")?.id, "r-l")
        XCTAssertEqual(HeadLetterArea.shown(latest: lish, earlier: earlier, chosen: nil)?.id, "r-l")
    }

    /// **Mid-round the head shows the round arriving** (`lastRound`, the
    /// preview) and Earlier letters lists the finished ones behind it
    /// (`latestRounds`, which never holds a preview) — Task 2 review M6.
    func test_earlierLettersAreFinishedAndTheHeadShowsWhatArrives() throws {
        let previous = run("r-l4", passId: "line", round: 4, letter: letter("Finished line."))
        let preview = run("r-l5", passId: "line", round: 5, letter: letter("Arriving."))
        XCTAssertEqual(ResolveHead.earlierLetters([previous], shown: preview, passes: passes).map(\.id),
                       ["r-l4"], "the finished letter behind the one arriving")
        let head = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/Resolve/ResolveHead.swift"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        XCTAssertTrue(head.contains("round: diagnostics.lastRound(docId: docId))"),
                      "the head's letter is the standing round, the preview included")
        XCTAssertTrue(head.contains("earlier: ResolveHead.earlierLetters(diagnostics.latestRounds(docId: docId),"),
                      "Earlier letters reads the finished rounds")
        XCTAssertTrue(head.contains(".id(docId)"), "until the faces change")
    }

    func test_earlierLettersIsHiddenWithOneLetter() {
        let only = run("r-l", passId: "line", round: 1, letter: letter("Line."))
        XCTAssertTrue(ResolveHead.earlierLetters([only], shown: only, passes: passes).isEmpty)
        XCTAssertTrue(ResolveHead.earlierLetters([], shown: nil, passes: passes).isEmpty)
        let check = run("c", passId: nil, round: nil, letter: letter("Check."), kind: .check)
        XCTAssertTrue(ResolveHead.earlierLetters([only], shown: check, passes: passes).count == 1,
                      "control: with the check's letter shown, the round's is an earlier one")
    }

    // MARK: - The wiring

    /// **Every row and head button reaches its verb, behind its gate** — a
    /// census of the production source, since the verbs themselves are the
    /// functions the tests above call (tripwire 33).
    func test_theHeadsButtonsReachTheirVerbsBehindTheirGates() throws {
        func code(_ type: String) throws -> String {
            SourceScan.codeLines(of: try SourceTree.sourceOfType(type, under: ["Maugham"]))
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
        let head = try code("PieceInLanguageHeadView")
        for token in [
            "ResolvePieceInLanguage.offersRun(docId: docId, isOpen: isOpen, mayTranslate: {",
            "if offersRunHere {",
            "let slot = ResolvePieceInLanguage.openSlot(isOpen: isOpen, isOpening: isOpening,",
            "TranslationRunStart.postureOfTheTranslator(forPiece: $0, in: documentStore).allows(.translate)",
            "Button(TranslationRunState.runTitle(pieceWord)) { runThisPiece() }",
            "let outcome = await ResolvePieceInLanguage.run(language: language, docId: docId,",
            "Button(TranslationRunState.cancelTitle) { verbs.cancel() }",
            "notice = await ResolvePieceInLanguage.confirmCast(",
            "lastRun: roster?.translationRuns.run(docId: docId, language: language),",
            "if ResolvePieceInLanguage.offersClear(",
            "isOpen: isOpen, authorPosture: documentStore.posture(forDocId: docId)) {",
            "confirmingClear = translation.leftOvers",
            "switch ResolvePieceInLanguage.clearDecision(shown: shown, now: now.leftOvers) {",
            "ResolvePieceInLanguage.elsewhereLine(relation, noun: noun, titleOf: {",
            "if let elsewhere = elsewhereLine {",
            "pipeline: ResolvePieceInLanguage.pipelineStatus(pipeline, relation: relation),",
            "}, relation: relation)",
            "notice = await ResolvePieceInLanguage.clearAndAnnounce(ids, docId: docId, language: language,",
            "Button(ResolveEditionItems.openTheReportTitle) { onShowRound(stopped) }",
            "Button(ResolveEditionItems.openTheReportTitle) { onShowRound(round) }",
            "TranslationReveal.post(ResolvePieceInLanguage.reveal(",
            "let answer = await TranslationPreflight.editionBudget(",
            "documentIds: [docId], language: language, store: store, documentStore: documentStore)",
        ] {
            XCTAssertTrue(head.contains(token), "the head lost \(token)")
        }
        let verbs = try code("PieceInLanguageHeadVerbs")
        XCTAssertTrue(verbs.contains("await TranslationRunStart.startRun("),
                      "Run reaches the one start, which asks the translator's settled posture")
        let caret = try code("PieceInLanguageCaretSection")
        for token in ["Button(SpotCheck.glossTitle) { runGloss(paragraphId) }",
                      "Button(SpotCheck.askTitle) { runAsk(paragraphId) }",
                      "await SpotCheck.gloss(", "await SpotCheck.askTheCollator(",
                      "verbs: authorVerbs,", "try await RulingPerformer.rule(",
                      "let refusal = await TranslatorsNote.commit("] {
            XCTAssertTrue(caret.contains(token), "the caret section lost \(token)")
        }
        let column = try code("RightColumn")
        XCTAssertTrue(column.contains(
            "ReadingLanguage.of(subject: subject, switched: editorControl.translationLanguage, sourceLanguage: publishCentre.sourceLanguage)"))
        XCTAssertTrue(column.contains("readIn: readingLanguage,"))
        let pane = try code("ResolvePane")
        XCTAssertTrue(pane.contains("ResolveScope.shown(faces: subject.faces, readIn: readIn,"))
        XCTAssertTrue(pane.contains("read = await ResolveEditionItems.readPiece("))
        // A reply's refusal is said on every row path.
        let noteVerbs = try code("ResolveNoteVerbs")
        XCTAssertTrue(noteVerbs.contains("await Self.reply(to: ann.id, with: reply, in: document,"))
        XCTAssertFalse(noteVerbs.contains("try? await document.acceptAnnotation(id: ann.id, userResponse: reply"),
                       "a reply is never swallowed")
    }

    // MARK: - The translation review pane is gone

    func test_theTranslationReviewPaneIsGone() throws {
        let files = try SourceTree.swiftFiles(under: "Maugham")
        XCTAssertFalse(files.contains { $0.hasSuffix("TranslationReviewPane.swift") })
        for file in files {
            let text = SourceScan.codeLines(of: try SourceTree.read(file)).joined(separator: "\n")
            for gone in ["TranslationReviewPane", "translationPane", ".translationReview"] {
                XCTAssertFalse(text.contains(gone), "\(file) still names \(gone)")
            }
        }
        XCTAssertFalse(try SourceTree.read("Maugham/Views/RightColumnContent.swift").isEmpty, "control")
    }

    /// **Every capability the translation review pane had has a home, or is
    /// named gone with its reason** — built from reading the pane at
    /// 670d03af before it was deleted; one row per display, state, refusal,
    /// empty state and verb (Task 7's lesson: a census of verbs alone lost
    /// four of the desk's). Each home is a code token in a production file.
    func test_everyReviewPaneCapabilityHasAHome() throws {
        let resolve = "Maugham/Views/Resolve/"
        let head = resolve + "ResolvePieceInLanguage.swift"
        let caret = resolve + "PieceInLanguageCaretSection.swift"
        let homes: [(capability: String, file: String, token: String)] = [
            ("\"No translation yet\"", head, "\"none of its \\(missing) paragraphs translated yet\""),
            ("the caret paragraph's source", caret,
             "if !control.showsSourceUnder, let source = document.paragraph(id: selected.paragraphId),"),
            ("the caret paragraph's freshness chip", caret, "TranslationStatusChip(status: selected.status)"),
            ("no caret paragraph: a placeholder", caret, "Text(entries.isEmpty ? Self.noSurfaceLine : Self.placeCaretLine)"),
            ("Gloss", caret, "Button(SpotCheck.glossTitle) { runGloss(paragraphId) }"),
            ("Ask the Collator", caret, "Button(SpotCheck.askTitle) { runAsk(paragraphId) }"),
            ("busy while the window's runner is out", caret,
             "private var busy: Bool { spotChecking || roster?.coldCall.isRunning == true }"),
            ("the in-flight spinner", caret, "if spotChecking { ProgressView().controlSize(.small) }"),
            ("a refused spot-check said", caret, "if case .refused(let sentence) = gloss { return sentence }"),
            ("the not-wired refusal", caret, "notice = SpotCheck.notWiredRefusal"),
            ("the gloss", caret, "Text(SpotCheck.glossLabel)"),
            ("the collator's overall", caret, "Text(report.overall)"),
            ("a departure's row", caret, "DepartureRowView("),
            ("Fine on a departure (transient)", caret, "onFine: { dismissedDepartures.insert(row.id) },"),
            ("Keep mine", caret, "TranslatorsNoteSheet("),
            ("Keep mine invalidates the craft-intent cache", caret,
             "instruction, target: target, home: home, store: store, world: world,"),
            ("Make it a rule", caret, "RoundRuleSheet(seed: seed, language: language,"),
            ("a departure filed once", caret, "isSettled: settledDepartures.contains(row.id),"),
            ("the filings' provenance", caret, "static let keepMineProvenance = \"spot-check, keep mine\""),
            ("a departure reveals its paragraph in the language", caret,
             "TranslationReveal.post(.init(docId: document.docId, language: language,"),
            ("an answer belongs to the paragraph it was asked about", caret,
             "guard Self.answerStillBelongs(askedAbout: paragraphId, selected: selected?.paragraphId)"),
            ("answers cleared when the caret moves", caret,
             ".onChange(of: selected?.paragraphId) { _, _ in clear() }"),
            ("a table's cells under the caret", caret, "TranslationCellsSection("),
            ("the caret section only on the open piece", head,
             "if isOpen, let document = documentStore.document(forDocId: docId), let control = editorControl {"),
            ("open queries in the language", resolve + "ResolveReader.swift",
             "inScope.contains($0.docId) && ResolveEditionItems.isQuestion($0.annotation, in: language)"),
            ("\"No open queries for this language.\"", head, "every question is answered "),
            ("Reply", resolve + "ResolveDialogs.swift",
             "verbs.replyToQuery(target.document, target.annotation, reply: reply)"),
            ("a refused reply said", resolve + "ResolveNoteVerbs.swift",
             "MaughamEvent.postNotice(sentence, projectURL: document.opStore.projectURL)"),
            ("Answer as ruling", resolve + "ResolveDialogs.swift", "QueryRulingSheet("),
            ("a refused ruling said", resolve + "ResolveDialogs.swift", "\"That answer could not be filed\","),
            ("the author's verbs follow the posture", resolve + "ResolvePane.swift", "AnnotationRowVerbs.decide("),
            ("left-over translations listed", head, "PieceInLanguageLeftOvers(leftOvers: translation.leftOvers, preview: !shown.wrappedValue)"),
            ("Remove All", head, "confirmingClear = translation.leftOvers"),
            ("Remove hidden where the author may not translate", head, "if ResolvePieceInLanguage.offersClear("),
            ("a Clear re-derives every surface", head,
             "MaughamEvent.post(.maughamTranslationDidUpdate, to: .project(for: projectURL),"),
            ("a Clear signs as the author, behind the door", head,
             "documentId: docId, actor: .author, identities: identities,"),
            ("⌘⌥L opens the translator's questions", resolve + "ResolveFilter.swift",
             "case .questions: requested = [.questions]"),
        ]
        let gone: [String: String] = [
            "\"Not in translation review\"":
                "there is no review mode: the list follows the reading language, and a piece read in Source lists the source's",
            "a refused purge only logged":
                "a refused Clear is said (`clearAndAnnounce` posts the sentence and returns it) — RULING-54's honesty rule",
            "Remove on one left-over":
                "one Clear for the group (the plan's 'one group with Clear'): a left-over is stale by definition and recreatable",
            "the left-over's paragraph id":
                "it named a paragraph that no longer exists; the text is what the writer can recognise",
        ]
        XCTAssertEqual(homes.count + gone.count, 41, "one row per line of the capability table")
        XCTAssertEqual(Set(homes.map(\.capability)).count, homes.count, "a capability is listed once")
        XCTAssertTrue(Set(homes.map(\.capability)).isDisjoint(with: gone.keys))
        var lost: [String] = []
        var sources: [String: String] = [:]
        for home in homes {
            if sources[home.file] == nil {
                sources[home.file] = SourceScan.codeLines(of: try SourceTree.read(home.file))
                    .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            }
            if !(sources[home.file] ?? "").contains(home.token) {
                lost.append("\(home.capability): \(home.file) lacks \(home.token)")
            }
        }
        XCTAssertEqual(lost, [], "a review pane capability lost its home:\n" + lost.joined(separator: "\n"))
    }
}

import XCTest
import MaughamCore
@testable import Maugham

/// **View ▸ Margin's marks, pure** (shell p5 Task 2): a dot is an open note
/// a person wrote, asked of the note's owner and never its stamp; a tick is a
/// paragraph a check or a round flagged, among what To resolve's selection
/// shows, one per paragraph whatever the count; nothing in focus mode or
/// over a translation; the review render takes the dots.
final class MarginMarksTests: XCTestCase {

    // MARK: - Builders

    private let t = Date(timeIntervalSince1970: 1_700_000_000)
    private let denver = AnnotationAuthor(sourceKind: .human, displayName: "Denver")
    private let ada = AnnotationAuthor(sourceKind: .human, displayName: "Ada")
    private let claude = AnnotationAuthor(sourceKind: .claude, displayName: "Claude")

    private func note(_ id: String, pid: String = "aa11", author: AnnotationAuthor?,
                      span: Range<Int>? = nil, status: AnnotationStatus = .open,
                      runId: String? = nil, round: Int? = nil, passId: String? = nil) -> Annotation {
        Annotation(id: id, kind: .comment, paragraphId: pid, body: "words a model wrote \(id)",
                   suggestedText: nil, priorText: nil, createdAt: t, createdBySession: nil,
                   status: status, userResponse: nil, resolvedAt: nil, isStale: false,
                   author: author, resolvedSpanRange: span, reviewPassId: passId,
                   compilerRunId: runId, compilerRound: round)
    }

    private func item(_ annotation: Annotation) -> ResolveItem {
        .note(ProjectAnnotation(docId: "doc-a", annotation: annotation))
    }

    private func finding(_ id: String, pid: String) -> ResolveItem {
        .finding(docId: "doc-a", Diagnostic(
            id: id, docId: "doc-a", anchor: .init(paragraphId: pid, anchorText: "x"),
            body: "a long message the check wrote about \(id)", category: nil, runId: "run-1",
            kind: .conformanceStrain))
    }

    private func todo(_ id: String, pid: String) -> ResolveItem {
        .todo(WriterTask(id: id, kind: .paneCreated, anchor: TaskAnchor(docId: "doc-a", paragraphId: pid),
                         body: id, status: .open, priority: 0, parentTaskId: nil,
                         createdAt: t, createdBySession: nil))
    }

    /// The owners, by note id; anything unnamed is unknown.
    private func owners(_ map: [String: NoteOwner]) -> (Annotation) -> NoteOwner {
        { map[$0.id] ?? .unknown }
    }

    private func marks(_ setting: MarginSetting, notes: [Annotation], owners map: [String: NoteOwner],
                       extra: [ResolveItem] = [], selection: Set<ResolveSource> = [],
                       focusMode: Bool = false, readingTranslation: Bool = false,
                       reviewRenderIsOn: Bool = false) -> MarginMarks {
        MarginMarks.of(setting: setting, notes: notes, owner: owners(map),
                       items: notes.map(item) + extra, selection: selection, localName: "Denver",
                       focusMode: focusMode, readingTranslation: readingTranslation,
                       reviewRenderIsOn: reviewRenderIsOn)
    }

    // MARK: - Off

    func test_offDrawsNothing() {
        let mine = note("n1", author: denver)
        let result = marks(.off, notes: [mine], owners: ["n1": .verified(.author, ofThisWriter: true)],
                           extra: [finding("s1", pid: "bb22")])
        XCTAssertEqual(result, .none)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Dots: a person's note

    func test_aPersonsNoteIsADotAndATint() {
        let mine = note("n1", pid: "aa11", author: denver, span: 4..<9)
        let reviewers = note("n2", pid: "bb22", author: ada)
        let result = marks(.peoplesNotes, notes: [mine, reviewers], owners: [
            "n1": .verified(.author, ofThisWriter: true),
            "n2": .verified(.author, ofThisWriter: false),
        ])
        let palette = ReviewPalette()
        XCTAssertEqual(result.dots, [
            .init(paragraphId: "aa11", span: 4..<9, annotationId: "n1", name: "Denver",
                  colour: palette.color(for: mine.author), person: ReviewPalette.person(mine.author)),
            .init(paragraphId: "bb22", span: nil, annotationId: "n2", name: "Ada",
                  colour: palette.color(for: reviewers.author), person: ReviewPalette.person(reviewers.author)),
        ], "the writer's note tints its words; an admitted reviewer's is a person's too")
        // Each dot takes its person's pencil — the review card's colour —
        // never the assistant's reserved one (closing round B).
        XCTAssertFalse(result.dots.contains { $0.colour == ReviewPalette.claudeTerracotta })
        XCTAssertEqual(result.ticks, [], "People's Notes draws no ticks")
    }

    /// **One mark of several people is grey, decided by who they are**
    /// (closing round B2, M3): two people who share a pencil tone on one
    /// line draw grey; one person's two notes draw their colour.
    func test_severalPeopleOnOneMarkAreGreyEvenSharingATone() {
        let shared = ReviewPalette.humanTones[0]
        func place(_ id: String, _ person: String) -> MarginPlace {
            MarginPlace(mark: .dot(annotationId: id, name: person, colour: shared, person: person),
                        paragraphId: "aa11", anchor: 0, tint: nil)
        }
        let two = MarginOverlayView.Drawn(places: [place("n1", "ada"), place("n2", "bea")],
                                          rect: .zero, hitRect: .zero, tintRects: [])
        XCTAssertEqual(two.colour, MarginOverlayView.dotColor, "two people, one tone: grey")
        let one = MarginOverlayView.Drawn(places: [place("n1", "ada"), place("n2", "ada")],
                                          rect: .zero, hitRect: .zero, tintRects: [])
        XCTAssertEqual(one.colour, shared, "one person's two notes: their pencil")
    }

    /// The disable experiment's test: let the assistant count as a person
    /// and this goes red.
    func test_anAssistantNoteIsNeverADotWhateverItsStamp() {
        let stampedHuman = note("n1", author: denver)
        let stampedClaude = note("n2", author: claude)
        for setting in [MarginSetting.peoplesNotes, .everythingFlagged] {
            let result = marks(setting, notes: [stampedHuman, stampedClaude], owners: [
                "n1": .verified(.assistant, ofThisWriter: true),
                "n2": .verified(.assistant, ofThisWriter: true),
            ])
            XCTAssertEqual(result.dots, [], "\(setting): the seal is the assistant's, the stamp is not read")
        }
        for machine in [DeviceActor.translator, .maugham] {
            let result = marks(.peoplesNotes, notes: [stampedHuman], owners: ["n1": .verified(machine, ofThisWriter: true)])
            XCTAssertEqual(result.dots, [], "\(machine)")
        }
    }

    /// A note no seal covers — a book older than the signed op log, a Mac
    /// with no key, a note not sealed yet — goes by its own stamp: a human
    /// stamp is a dot, a machine stamp is not.
    func test_anUnsignedNoteGoesByItsStamp() {
        let human = note("n1", author: denver)
        let machine = note("n2", pid: "bb22", author: claude)
        let result = marks(.peoplesNotes, notes: [human, machine],
                           owners: ["n1": .stamped(.human), "n2": .stamped(.claude)])
        XCTAssertEqual(result.dots.map(\.annotationId), ["n1"])
    }

    func test_aNoteSealedByAKeyNotOursIsNeverADot() {
        let result = marks(.peoplesNotes, notes: [note("n1", author: denver)], owners: ["n1": .unknown])
        XCTAssertEqual(result, .none)
    }

    func test_aSettledNoteIsNoDot() {
        let result = marks(.peoplesNotes, notes: [note("n1", author: denver, status: .archived)],
                           owners: ["n1": .verified(.author, ofThisWriter: true)])
        XCTAssertEqual(result.dots, [])
    }

    // MARK: - Ticks: a check's or a round's item

    func test_aFindingIsOneTickHoweverMany() {
        let result = marks(.everythingFlagged, notes: [], owners: [:], extra: [
            finding("s1", pid: "bb22"), finding("s2", pid: "bb22"), finding("s3", pid: "bb22"),
            finding("s4", pid: "cc33"),
        ])
        XCTAssertEqual(result.ticks, ["bb22", "cc33"], "one tick per paragraph, whatever the count")
        XCTAssertEqual(result.dots, [])
    }

    /// A round's notes are minted under the assistant's key: a tick, never a
    /// dot. A check's notes (run, no round) are ticks too.
    func test_aRoundNoteIsATickNotADot() {
        let round = note("r1", pid: "bb22", author: claude, runId: "run-9", round: 2, passId: "pass-1")
        let check = note("c1", pid: "cc33", author: claude, runId: "run-8")
        let result = marks(.everythingFlagged, notes: [round, check], owners: [
            "r1": .verified(.assistant, ofThisWriter: true),
            "c1": .verified(.assistant, ofThisWriter: true),
        ])
        XCTAssertEqual(result.ticks, ["bb22", "cc33"])
        XCTAssertEqual(result.dots, [])
    }

    /// The writer's own note is a dot, never also a tick; her to-do is
    /// neither; another person's note outside a round is a dot alone.
    func test_theWritersToDoIsNeither() {
        let mine = note("n1", pid: "aa11", author: denver)
        let result = marks(.everythingFlagged, notes: [mine],
                           owners: ["n1": .verified(.author, ofThisWriter: true)],
                           extra: [todo("t1", pid: "bb22")])
        XCTAssertEqual(result.ticks, [], "a to-do flags nothing")
        XCTAssertEqual(result.dots.map(\.annotationId), ["n1"])
    }

    /// A person's note in a review pass is a dot, and not also a tick.
    func test_aPersonsPassNoteIsADotNotATick() {
        let reviewers = note("n1", pid: "aa11", author: ada, passId: "pass-1")
        let result = marks(.everythingFlagged, notes: [reviewers],
                           owners: ["n1": .verified(.author, ofThisWriter: false)])
        XCTAssertEqual(result.ticks, [])
        XCTAssertEqual(result.dots.map(\.annotationId), ["n1"])
    }

    func test_theTicksFollowTheSelection() {
        let round = note("r1", pid: "bb22", author: claude, runId: "run-9", round: 2, passId: "pass-1")
        let extra = [finding("s1", pid: "cc33")]
        let owners: [String: NoteOwner] = ["r1": .verified(.assistant, ofThisWriter: true)]
        XCTAssertEqual(marks(.everythingFlagged, notes: [round], owners: owners, extra: extra,
                             selection: []).ticks, ["bb22", "cc33"], "empty shows everything")
        XCTAssertEqual(marks(.everythingFlagged, notes: [round], owners: owners, extra: extra,
                             selection: [.checks]).ticks, ["cc33"])
        XCTAssertEqual(marks(.everythingFlagged, notes: [round], owners: owners, extra: extra,
                             selection: [.pass("pass-1")]).ticks, ["bb22"])
        XCTAssertEqual(marks(.everythingFlagged, notes: [round], owners: owners, extra: extra,
                             selection: [.mine]).ticks, [], "Mine alone: no ticks")
    }

    // MARK: - What hides or yields the marks

    func test_focusModeHidesEverything() {
        let result = marks(.everythingFlagged, notes: [note("n1", author: denver)],
                           owners: ["n1": .verified(.author, ofThisWriter: true)],
                           extra: [finding("s1", pid: "bb22")], focusMode: true)
        XCTAssertEqual(result, .none)
    }

    func test_aPieceReadInALanguageDrawsNothing() {
        let result = marks(.everythingFlagged, notes: [note("n1", author: denver)],
                           owners: ["n1": .verified(.author, ofThisWriter: true)],
                           extra: [finding("s1", pid: "bb22")], readingTranslation: true)
        XCTAssertEqual(result, .none)
    }

    func test_theReviewRenderTakesTheDots() {
        let result = marks(.everythingFlagged, notes: [note("n1", author: denver)],
                           owners: ["n1": .verified(.author, ofThisWriter: true)],
                           extra: [finding("s1", pid: "bb22")], reviewRenderIsOn: true)
        XCTAssertEqual(result.dots, [], "the review render already marks the same notes")
        XCTAssertEqual(result.ticks, ["bb22"], "the ticks still draw")
    }

    // MARK: - The review render's set (the owner's answer to Question 2)

    /// Under read-through the review render's cards are a person's notes
    /// only: the same predicate as the dots.
    func test_onlyAPersonsNotesAreDrawnBesideTheText() {
        let mine = note("n1", author: denver)
        let reviewers = note("n2", author: ada)
        let claudes = note("n3", author: claude)
        let disguised = note("n4", author: denver)
        let legacy = note("n5", author: denver)
        let drawn = MarginMarks.drawnBesideTheText([mine, reviewers, claudes, disguised, legacy], owner: owners([
            "n1": .verified(.author, ofThisWriter: true),
            "n2": .verified(.author, ofThisWriter: false),
            "n3": .verified(.assistant, ofThisWriter: true),
            "n4": .verified(.assistant, ofThisWriter: true),
            "n5": .stamped(.human),
        ]))
        XCTAssertEqual(drawn.map(\.id), ["n1", "n2", "n5"])
    }

    // MARK: - Fix round 1: the click's faces (M5), the ticks' selection (M6)

    private let structure = [StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md")]

    /// A click moves the faces to the open piece, as the line over the
    /// prose does, so the column never opens on another subject's list.
    func test_aClickMovesTheFacesToTheOpenPiece() throws {
        let payload: [AnyHashable: Any] = [MaughamEvent.annotationDocIdKey: "doc-a",
                                           MaughamEvent.marginParagraphIdKey: "bb22"]
        let onTheBook = try XCTUnwrap(MarginMirrorModifier.paragraphJump(
            payload, subject: WindowSubject(open: .item("doc-a"), faces: .project), structure: structure))
        XCTAssertEqual(onTheBook.subject, WindowSubject(open: .item("doc-a"), faces: .item("doc-a")))
        XCTAssertEqual(onTheBook.jump, ProjectWindow.StrainJump(
            showInspector: true, position: .resolve, request: .showParagraph(docId: "doc-a", paragraphId: "bb22")))
        let already = WindowSubject(open: .item("doc-a"), faces: .item("doc-a"))
        XCTAssertEqual(MarginMirrorModifier.paragraphJump(payload, subject: already, structure: structure)?.subject,
                       already, "faces already on the piece stay")
        XCTAssertNil(MarginMirrorModifier.paragraphJump([:], subject: already, structure: structure))
    }

    /// The ticks follow the open piece's OWN list's selection: a Book's or
    /// an edition's list's choice is not kept for it.
    func test_theTicksFollowThePiecesOwnListOnly() {
        var kept: [String: Set<ResolveSource>] = [:]
        kept = ProjectWindow.recordingSelection(
            ResolveShownSelection(scope: .piece(docId: "doc-a", includesBookLevel: false), selection: [.checks]),
            into: kept)
        XCTAssertEqual(kept, ["doc-a": [.checks]])
        kept = ProjectWindow.recordingSelection(
            ResolveShownSelection(scope: .pieces(docIds: ["doc-a"], includesBookLevel: true), selection: [.mine]),
            into: kept)
        XCTAssertNil(kept["doc-a"], "N3: the piece's list is gone, and its filter with it — "
                     + "the Book's list shows everything, so the ticks do")
        kept = ProjectWindow.recordingSelection(
            ResolveShownSelection(scope: .piece(docId: "doc-a", includesBookLevel: false), selection: [.mine]),
            into: kept)
        kept = ProjectWindow.recordingSelection(
            ResolveShownSelection(scope: .piece(docId: "doc-b", includesBookLevel: false), selection: []),
            into: kept)
        XCTAssertNil(kept["doc-a"], "N3: another piece's list reset the filter, as the pane does")
        XCTAssertEqual(kept, ["doc-b": []])
    }

    // MARK: - VoiceOver and the menu

    func test_eachMarkSaysWhatItMarks() {
        XCTAssertEqual(MarginMarks.accessibilityLabel(ofDots: ["Ada"]), "Note by Ada")
        XCTAssertEqual(MarginMarks.accessibilityLabel(ofDots: [""]), "Note")
        XCTAssertEqual(MarginMarks.accessibilityLabel(ofDots: ["Ada", "Denver"]), "Notes",
                       "several beside one line: no names, no count")
        XCTAssertEqual(MarginMarks.tickAccessibilityLabel, "Flagged paragraph")
    }

    /// The menu's three items, checked by the key window's setting (the
    /// `Toggle`'s `isOn` reads this); none with no project window.
    func test_theMenusItemsAreCheckedByTheSetting() {
        XCTAssertEqual(MarginSetting.allCases.map(\.title), ["Off", "People\u{2019}s Notes", "Everything Flagged"])
        for current in MarginSetting.allCases {
            XCTAssertEqual(MarginSetting.allCases.filter { MarginMarks.isChecked($0, current: current) },
                           [current])
        }
        XCTAssertEqual(MarginSetting.allCases.filter { MarginMarks.isChecked($0, current: nil) }, [])
    }

    /// Remembered per project: absent decodes Off; a value round-trips.
    func test_theSettingIsRememberedAndOffByDefault() throws {
        XCTAssertEqual(UIState().marginSetting, .off)
        let legacy = try JSONDecoder().decode(UIState.self, from: Data(#"{"schemaVersion":5}"#.utf8))
        XCTAssertEqual(legacy.marginSetting, .off)
        var state = UIState()
        state.marginSetting = .everythingFlagged
        let back = try JSONDecoder().decode(UIState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back.marginSetting, .everythingFlagged)
        let unknown = try JSONDecoder().decode(UIState.self, from: Data(#"{"schemaVersion":5,"marginSetting":"loud"}"#.utf8))
        XCTAssertEqual(unknown.marginSetting, .off)
    }

    func test_theSettingEventCarriesItsValue() {
        XCTAssertEqual(MaughamEvent.marginSetting(of: [MaughamEvent.marginSettingKey: "myNotes"]), .peoplesNotes)
        // Renamed in Task 7; the stored value is not, so a chosen setting survives.
        XCTAssertEqual(MarginSetting.peoplesNotes.rawValue, "myNotes")
        XCTAssertNil(MaughamEvent.marginSetting(of: [MaughamEvent.marginSettingKey: "loud"]))
    }
}

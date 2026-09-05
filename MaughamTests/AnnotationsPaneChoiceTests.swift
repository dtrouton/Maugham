import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The queue's two doors into the lessons ledger** (editorial letter P2 Task
/// 8, spec §6): *This is a choice*, the second stet's offer, and *Keep as
/// lesson…*.
///
/// Two registers of assertion, deliberately:
///
/// - the **verbs** are driven against a real `ProjectStore` over a temp project
///   (`LessonLedgerVerbsTests`' discipline and for its reason: what these are
///   for is what lands in the writer's own file, and the statement machinery
///   that decides it is exactly what a fake would stub out), with every
///   read-back through `LessonsLedger`'s own grammar rather than a hand-built
///   expectation about the line's shape;
/// - the **controls** are mounted through `TestWindow` and pressed through
///   `accessibilityPerformPress`, this pane family's established delivery path
///   (`AnnotationsPassOrderNudgeVerbsTests`, `ReviewRoundCockpitTests`).
///
/// Paragraph-id literals here are four characters from
/// `[0-9a-hjkmnp-tv-z]` (tripwire 8), because these annotations cross the
/// `.md` ↔ op log boundary.
@MainActor
final class AnnotationsPaneChoiceTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var temp: TempDirectory!

    override class func setUp() {
        super.setUp()
        // Mounted rows resolve fonts through production typography — the fontd
        // cold-start window (CLAUDE.md).
        FontWarmup.ensure()
    }

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() {
        for window in windows {
            for sheet in window.sheets { window.endSheet(sheet) }
            window.orderOut(nil)
        }
        windows.removeAll()
        temp = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private struct Harness {
        let store: ProjectStore
        let documentStore: DocumentStore
        let document: Document
        let url: URL
    }

    /// A real novel on disk with its first chapter open, worked through Line.
    private func makeHarness(named name: String = "Choice") async throws -> Harness {
        let url = try await ProjectFactory.createNovelProject(
            named: name, in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        let documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore

        let item = try XCTUnwrap(store.manifest.structure.first)
        let path = try XCTUnwrap(item.path)
        // A paragraph to anchor on: `addAnnotation` refuses an anchorless
        // `.query`, which is the shape a letter's question mints as.
        try "The fog came in over the water, and stayed.\n".write(
            to: url.appendingPathComponent(path), atomically: true, encoding: .utf8)
        let document = try await Document.load(
            url: url.appendingPathComponent(path),
            device: "test-mac", session: "s", presenter: nil)
        documentStore.register(document: document, for: path)

        return Harness(store: store, documentStore: documentStore,
                       document: document, url: url)
    }

    /// A question raised under a habit, exactly as a round mints one: anchored,
    /// compiler-authored, pass-stamped, carrying the ledger heading.
    @discardableResult
    private func mintQuestion(
        _ fx: Harness, body: String = "Whose house is it, in this paragraph?",
        heading: String? = "Filter words", passId: String? = "line",
        round: Int? = 3
    ) async throws -> String {
        let pid = try XCTUnwrap(fx.document.sequence.first)
        return try await fx.document.addAnnotation(
            kind: .query, paragraphId: pid, body: body,
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Le Guin"),
            reviewPassId: passId,
            compilerRunId: "run-1", compilerRound: round,
            compilerLessonHeading: heading)
    }

    /// **A second chapter, open and registered** — what makes the project
    /// bigger than the pane's own document.
    ///
    /// Registered rather than left on disk so the project walk reads its LIVE
    /// projection: an op appended a moment ago is in the document before it is
    /// in `.maugham/ops/`, and a test that raced the debounce would be
    /// asserting about a walk that had not seen its own premise yet.
    @discardableResult
    private func makeSecondChapter(
        _ fx: Harness, titled title: String = "Chapter 2"
    ) async throws -> Document {
        let item = try await fx.store.addStructureItem(
            parentId: nil, title: title, kind: .document(extension: "md"))
        let path = try XCTUnwrap(item.path)
        try "She counted the bells and lost the number twice.\n".write(
            to: fx.url.appendingPathComponent(path), atomically: true,
            encoding: .utf8)
        let document = try await Document.load(
            url: fx.url.appendingPathComponent(path),
            device: "test-mac", session: "s2", presenter: nil)
        fx.documentStore.register(document: document, for: path)
        return document
    }

    /// A question raised under a habit in a document that is not the pane's.
    @discardableResult
    private func mintQuestion(
        in document: Document, body: String,
        heading: String? = "Filter words"
    ) async throws -> String {
        let pid = try XCTUnwrap(document.sequence.first)
        return try await document.addAnnotation(
            kind: .query, paragraphId: pid, body: body,
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Le Guin"),
            reviewPassId: "line",
            compilerRunId: "run-1", compilerRound: 3,
            compilerLessonHeading: heading)
    }

    private func ledger(_ fx: Harness) -> String? {
        LessonLedgerVerbs.ledgerText(store: fx.store)
    }

    private func choices(_ fx: Harness) -> [String] {
        LessonsLedger.choices(in: ledger(fx) ?? "")
    }

    private func status(_ fx: Harness, _ id: String) -> AnnotationStatus? {
        fx.document.annotations(filter: AnnotationFilter(statuses: nil))
            .first { $0.id == id }?.status
    }

    /// A plain annotation value, for the predicate and row tests that need no
    /// document at all.
    private func note(
        id: String = "a1", kind: AnnotationKind = .query,
        status: AnnotationStatus = .open,
        heading: String? = "Filter words",
        passId: String? = "line",
        runId: String? = "run-1"
    ) -> Annotation {
        Annotation(
            id: id, kind: kind, paragraphId: "3k7p",
            body: "You reach for \u{201C}she felt\u{201D} where the image "
                + "would carry it on its own.",
            suggestedText: nil, priorText: nil,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            createdBySession: nil, status: status, userResponse: nil,
            resolvedAt: nil, isStale: false,
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Le Guin"),
            reviewPassId: passId,
            compilerRunId: runId, compilerRound: 3,
            lessonHeading: heading)
    }

    // MARK: - Mounting

    /// The offer the mounted pane last raised. An alert belongs to the window
    /// server and a headless mount cannot press its buttons — this is the
    /// witness `AnnotationsPane.onChoiceOfferChanged` exists for, and it is
    /// `DesignGateTests`' own way past the same wall.
    private var offer: ChoiceOffer?

    private func mountPane(
        _ fx: Harness, scope: AnnotationScope = .document
    ) -> NSWindow {
        let view = AnnotationsPane(
            document: fx.document,
            store: fx.store,
            documentStore: fx.documentStore,
            scope: .constant(scope),
            onTravel: { _ in },
            orchestrator: nil,
            diagnostics: nil,
            onChoiceOfferChanged: { [self] in offer = $0 })
            .environment(UserPreferences(
                defaults: UserDefaults(suiteName: "PaneChoice-\(UUID())")!))
        // Wide enough that `actionRow`'s worded variant is the one drawn, so a
        // control is found by the words the writer reads rather than by an SF
        // Symbol name.
        let window = TestWindow.mount(AnyView(view),
                                      size: CGSize(width: 620, height: 800))
        windows.append(window)
        pump()
        return window
    }

    private func mountRow(
        _ annotation: Annotation, ledgerText: String? = nil
    ) -> NSWindow {
        let row = AnnotationRow(
            annotation: annotation,
            onAccept: {}, onReject: {}, onArchive: {}, onReply: {},
            onJumpToParagraph: {},
            ledgerText: ledgerText)
        let window = TestWindow.mount(AnyView(row),
                                      size: CGSize(width: 620, height: 300))
        windows.append(window)
        pump()
        return window
    }

    // MARK: - Accessibility (mirrors `AnnotationsPassOrderNudgeVerbsTests`)

    private func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }

    private func axElements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        let children = axAttribute(root, "accessibilityChildren") as? [AnyObject] ?? []
        return [root] + children.flatMap { axElements(under: $0, depth: depth + 1) }
    }

    private func axTree(in window: NSWindow) throws -> [AnyObject] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process, so SwiftUI "
                + "never built the tree this test reads")
        }
        return axElements(under: try XCTUnwrap(window.contentView))
    }

    private func buttonLabels(in window: NSWindow) throws -> [String] {
        try axTree(in: window)
            .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            .compactMap { axAttribute($0, "accessibilityLabel") as? String }
    }

    /// A control found by the words its tooltip carries — the same words the
    /// writer reads. The queue's resolved toggle is an unlabelled icon button,
    /// and its help text is the only thing on it that says what it does.
    private func control(withHelpContaining text: String,
                         in window: NSWindow) throws -> NSObject {
        let tree = try axTree(in: window)
        let match = tree.first { element in
            let help = (axAttribute(element, "accessibilityHelp") as? String) ?? ""
            return help.contains(text)
        }
        return try XCTUnwrap(
            match as? NSObject,
            "no control whose tooltip contains \u{201C}\(text)\u{201D} reached "
            + "the hosted view")
    }

    /// **A press delivered to a mounted control, once the window is on
    /// screen.** `TestWindow.mount` orders the window in synchronously, but
    /// the press still wants the layout pass the button lookup may have cut
    /// short: a control's presence in the accessibility tree is not the
    /// premise a synthetic press needs, and a press that lands nowhere is
    /// silent.
    @discardableResult
    private func press(_ label: String, in window: NSWindow) throws -> NSObject {
        let button = try button(labelled: label, in: window)
        waitUntil({ window.isVisible }, timeout: 2)
        pump()
        _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
        return button
    }

    private func button(labelled label: String, in window: NSWindow) throws -> NSObject {
        var lastAll: [AnyObject] = []
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            lastAll = try axTree(in: window)
                .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            if let match = lastAll.first(
                where: { (axAttribute($0, "accessibilityLabel") as? String) == label }
            ) as? NSObject {
                return match
            }
            pump(0.05)
        }
        return try XCTUnwrap(
            lastAll.first { (axAttribute($0, "accessibilityLabel") as? String) == label }
                as? NSObject,
            "no button labelled \u{201C}\(label)\u{201D} reached the hosted view. "
            + "Buttons found: "
            + "\(lastAll.map { axAttribute($0, "accessibilityLabel") as? String ?? "nil" })")
    }

    // MARK: - The verb draws only on the four-way condition

    /// **Four predicates, four controls, one per flip.**
    ///
    /// A row that drew the verb on three of the four would put a press on
    /// screen that files a decision about a note that is not a coach's
    /// observation, or files the same decision twice. Each control below flips
    /// exactly one and asserts the words are gone.
    func test_theChoiceVerbDrawsOnlyOnTheFourWayCondition() throws {
        let subject = mountRow(note())
        let subjectLabels = try buttonLabels(in: subject)
        XCTAssertTrue(
            subjectLabels.contains(QueueLedgerVerbs.choiceTitle),
            "premise: an open, compiler-authored question carrying a habit "
            + "heading is exactly the row this verb is for. Buttons: "
            + "\(subjectLabels)")

        let controls: [(String, Annotation)] = [
            ("no habit heading \u{2014} there is nothing to file",
             note(heading: nil)),
            ("a person's note \u{2014} a habit is something a round noticed",
             note(runId: nil)),
            ("already settled \u{2014} filing again would date one decision twice",
             note(status: .stetted)),
            ("a craft note \u{2014} that door is Keep as lesson\u{2026}",
             note(kind: .craftNote)),
        ]
        for (why, annotation) in controls {
            let window = mountRow(annotation)
            let labels = try buttonLabels(in: window)
            XCTAssertFalse(
                labels.contains(QueueLedgerVerbs.choiceTitle),
                "the choice verb must not be drawn: \(why). Buttons: "
                + "\(labels)")
        }
    }

    /// The same truth table asked of the predicate itself, so a change to the
    /// row's layout cannot quietly take the rule with it. A blank heading is
    /// the fifth case and is treated as none — a button whose only outcome is
    /// `RulingFailure.emptyRuling` is worse than no button.
    func test_theChoicePredicateIsTheSameFourQuestions() {
        XCTAssertTrue(QueueLedgerVerbs.offersAChoice(note()))
        XCTAssertFalse(QueueLedgerVerbs.offersAChoice(note(heading: nil)))
        XCTAssertFalse(QueueLedgerVerbs.offersAChoice(note(heading: "   ")),
                       "a blank heading is no heading")
        XCTAssertFalse(QueueLedgerVerbs.offersAChoice(note(runId: nil)))
        XCTAssertFalse(QueueLedgerVerbs.offersAChoice(note(status: .stetted)))
        XCTAssertFalse(QueueLedgerVerbs.offersAChoice(note(kind: .craftNote)))
    }

    // MARK: - Pressing it files the choice AND stets

    /// **A row filed from the QUEUE carries no stage, and a row filed from a
    /// letter does** (P3 Task 5, global constraint 28). An annotation carries a
    /// pass and a round; it carries nothing about the writer's own delta, and
    /// a queue row naming a stage would be attributing one run's reading of
    /// the delta to whatever round happened to raise this note.
    ///
    /// Asserted with the control beside it, or the absence is evidence of
    /// nothing: the same lane, built for a letter whose run derived a stage,
    /// says the word.
    ///
    /// **Disable experiment** (2026-09-03): passing `stage: .drafting` from
    /// `QueueLedgerVerbs.provenance` reddens this \u{2014} *XCTAssertFalse
    /// failed - the queue\u{2019}s door passes `stage: nil`: from Le Guin\u{2019}s
    /// letter \u{00b7} Line \u{00b7} Lish \u{00b7} round 3 \u{00b7} drafting*.
    func test_aRowFiledFromTheQueueNamesNoStageAndALetterFiledRowDoes() async throws {
        let fx = try await makeHarness(named: "ChoiceNoStage")
        let queue = QueueLedgerVerbs.provenance(for: note(), store: fx.store)
        for word in [DraftStage.drafting.rawValue, DraftStage.revising.rawValue] {
            XCTAssertFalse(
                queue.contains(word),
                "the queue's door passes `stage: nil`: \(queue)")
        }

        let fromLetter = LessonLedgerVerbs.provenance(
            voice: "Le Guin",
            lane: LetterKeep.laneLine(
                passId: "line", round: 3, stage: .drafting, store: fx.store))
        XCTAssertEqual(
            fromLetter,
            "from Le Guin's letter \u{00b7} Line \u{00b7} Lish \u{00b7} round 3 "
            + "\u{00b7} drafting",
            "the control \u{2014} the same lane, with a run's stage on it")
    }

    /// The provenance is the note's own: the editor who wrote it, and the lane
    /// it was stamped with at the round it was raised in. A lesson outlives the
    /// note that raised it, so this is the only place that record is made.
    func test_theFiledRowNamesTheEditorAndTheLane() async throws {
        let fx = try await makeHarness(named: "ChoiceProvenance")
        let annotation = note()
        let provenance = QueueLedgerVerbs.provenance(for: annotation, store: fx.store)
        XCTAssertEqual(
            provenance, "from Le Guin's letter \u{00b7} Line \u{00b7} Lish \u{00b7} round 3",
            "the voice is the note's author and the lane is "
            + "`LetterKeep.laneLine` over the note's own pass and round")

        _ = await QueueLedgerVerbs.makeChoice(
            annotation, in: fx.document, store: fx.store, world: nil,
            undoManager: nil)
        let row = try XCTUnwrap(
            LessonsLedger.parse(ledger(fx) ?? "").entries.first)
        XCTAssertEqual(row.ruling.provenance, provenance,
                       "and it is that sentence the ledger line carries")
    }

    /// **A passless, un-round-stamped note still files** — the lane is simply
    /// absent rather than invented. The control for the assertion above.
    func test_aNoteWithNoPassFilesWithNoLane() async throws {
        let fx = try await makeHarness(named: "ChoiceNoLane")
        let annotation = Annotation(
            id: "a2", kind: .query, paragraphId: "3k7p", body: "b",
            suggestedText: nil, priorText: nil, createdAt: Date(),
            createdBySession: nil, status: .open, userResponse: nil,
            resolvedAt: nil, isStale: false,
            author: nil, compilerRunId: "run-1", lessonHeading: "Fragments")
        XCTAssertEqual(
            QueueLedgerVerbs.provenance(for: annotation, store: fx.store),
            "from Claude's letter",
            "a nil author reads as Claude (`AnnotationAuthorPresentation`), "
            + "and a note stamped with no pass has no lane to name")
    }

    // MARK: - A refused ruling changes nothing

    /// **Ruling first, and a refusal leaves the note open** — the ordering
    /// `QueryRuling.commit` argues for, one surface over.
    ///
    /// The refusal is the disk's own: with the project root read-only,
    /// `RulingPerformer.rule` cannot mint `lessons.md`, so nothing is filed.
    /// The claim is that nothing is stetted either.
    func test_aRefusedRulingLeavesTheNoteOpenAndFilesNothing() async throws {
        let fx = try await makeHarness(named: "ChoiceRefused")
        let id = try await mintQuestion(fx)
        let annotation = try XCTUnwrap(
            fx.document.annotations(filter: AnnotationFilter(statuses: nil))
                .first { $0.id == id })

        let fm = FileManager.default
        let original = try XCTUnwrap(
            fm.attributesOfItem(atPath: fx.url.path)[.posixPermissions] as? NSNumber)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fx.url.path)
        defer {
            try? fm.setAttributes([.posixPermissions: original],
                                  ofItemAtPath: fx.url.path)
        }

        let refusal = await QueueLedgerVerbs.makeChoice(
            annotation, in: fx.document, store: fx.store, world: nil,
            undoManager: nil)

        XCTAssertNotNil(refusal, "a ledger write that could not land must say so")
        XCTAssertEqual(
            status(fx, id), .open,
            "the stet is second, so a refused ruling leaves the note where the "
            + "writer can press again \u{2014} settling it here would take the "
            + "decision off screen with nothing filed")
        XCTAssertNil(ledger(fx), "and nothing was filed")
    }

    /// The control for the test above: with the same project WRITABLE, the same
    /// call lands both halves. Without this, a `makeChoice` that always refused
    /// would pass the assertions above for the wrong reason.
    func test_theSameCallOnAWritableProjectLandsBothHalves() async throws {
        let fx = try await makeHarness(named: "ChoiceWritable")
        let id = try await mintQuestion(fx)
        let annotation = try XCTUnwrap(
            fx.document.annotations(filter: AnnotationFilter(statuses: nil))
                .first { $0.id == id })

        let refusal = await QueueLedgerVerbs.makeChoice(
            annotation, in: fx.document, store: fx.store, world: nil,
            undoManager: nil)

        XCTAssertNil(refusal, "nothing here should have refused: \(refusal ?? "")")
        XCTAssertEqual(choices(fx), ["Filter words"])
        XCTAssertEqual(status(fx, id), .stetted)
    }

    /// A note with no heading refuses in words that say what to do instead,
    /// rather than trapping. Unreachable from the row — the verb is not drawn —
    /// and that is exactly why it must not crash if it is ever reached.
    func test_aHeadinglessNoteRefusesAndStetsNothing() async throws {
        let fx = try await makeHarness(named: "ChoiceHeadingless")
        let id = try await mintQuestion(fx, heading: nil)
        let annotation = try XCTUnwrap(
            fx.document.annotations(filter: AnnotationFilter(statuses: nil))
                .first { $0.id == id })

        let refusal = await QueueLedgerVerbs.makeChoice(
            annotation, in: fx.document, store: fx.store, world: nil,
            undoManager: nil)

        XCTAssertEqual(refusal, QueueLedgerVerbs.headinglessRefusal)
        XCTAssertEqual(status(fx, id), .open)
        XCTAssertNil(ledger(fx))
    }

    // MARK: - The second stet offers; the first does not

    /// **Cancel abandons.** Escape carries this arm (Denver's ruling, fix
    /// round 1), and it is the only one of the three that touches neither the
    /// ledger nor the note: a keystroke that settles a note is not a way out of
    /// a question, and a writer who pressed it to make the dialog go away would
    /// find the note gone from their queue.
    func test_cancelAbandonsTheOfferAndTouchesNothing() async throws {
        let fx = try await makeHarness(named: "CancelOffer")
        let twin = try await mintQuestion(fx, body: "An earlier one of these.")
        try await fx.document.stetAnnotation(id: twin)
        let id = try await mintQuestion(fx)

        let window = mountPane(fx)
        let stet = try button(labelled: "Stet", in: window)
        _ = stet.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.2)
        let raised = try XCTUnwrap(offer, "premise: the offer stands")

        raised.cancel()
        pump(0.4)
        XCTAssertNil(offer, "the offer is dropped")
        XCTAssertEqual(status(fx, id), .open,
                       "and the note is left exactly as the writer found it")
        XCTAssertNil(ledger(fx), "nothing filed")
    }

    /// The offer's own words, including the sentence about \u{2318}Z. One press
    /// does two things to two logs and only one of them is on the writer's undo
    /// stack; a writer who pressed \u{2318}Z expecting the whole act back would
    /// find the ledger row still there and no control on screen that made it.
    func test_theOfferSaysWhatUndoWillAndWillNotTakeBack() {
        XCTAssertEqual(
            QueueLedgerVerbs.secondStetTitle("Filter words"),
            "Make \u{201C}Filter words\u{201D} a choice?")
        XCTAssertTrue(
            QueueLedgerVerbs.secondStetHelp.contains(
                "The ledger entry stays; \u{2318}Z reopens the note."),
            "got: \(QueueLedgerVerbs.secondStetHelp)")
    }

    /// The predicate's own truth table, asked without a window — including the
    /// two things that make an offer wrong even with a twin present.
    func test_theSecondStetPredicate() {
        let subject = note(id: "a1")
        let stettedTwin = note(id: "a2", status: .stetted)

        XCTAssertNil(
            QueueLedgerVerbs.secondStetOffer(
                for: subject, among: [subject], ledgerText: nil),
            "a first stet asks nothing")
        XCTAssertEqual(
            QueueLedgerVerbs.secondStetOffer(
                for: subject, among: [subject, stettedTwin], ledgerText: nil),
            "Filter words",
            "a stetted twin under the same heading is the evidence")
        XCTAssertNil(
            QueueLedgerVerbs.secondStetOffer(
                for: subject, among: [subject, note(id: "a2", status: .open)],
                ledgerText: nil),
            "an OPEN twin is not a second stet")
        XCTAssertNil(
            QueueLedgerVerbs.secondStetOffer(
                for: subject,
                among: [subject, note(id: "a2", status: .stetted,
                                      heading: "filter words")],
                ledgerText: nil),
            "identity is the heading verbatim (`LessonsLedger.matches`) \u{2014} "
            + "a re-spelled heading names no twin")
        XCTAssertNil(
            QueueLedgerVerbs.secondStetOffer(
                for: subject, among: [subject, stettedTwin],
                ledgerText: "## Rulings\n\n- Choice: Filter words \u{2014} ruled 1 Sep 2026, from a letter\n"),
            "a heading already standing as a choice needs no second offer")
        XCTAssertNil(
            QueueLedgerVerbs.secondStetOffer(
                for: note(id: "a1", heading: nil), among: [stettedTwin],
                ledgerText: nil),
            "a note with no heading stets plainly, whatever else is stetted")
    }

    // MARK: - The twin is looked for across the project (P3 Task 8, ruling A)

    /// **A habit is the writer's, not a chapter's** (Denver's ruling A). The
    /// second stet's evidence is a twin under the same heading anywhere in the
    /// project, because the ledger it may file into is project-scope and a
    /// pattern that shows up once per chapter is exactly the pattern worth
    /// naming.
    ///
    /// Document scope, where the search is widest relative to what is on
    /// screen: the twin is in a chapter this pane is not showing.
    ///
    /// **Disable experiment.** With the press searching the pane's own document
    /// alone — `among: fx.document.annotations(filter: AnnotationFilter(statuses: nil))`,
    /// which is what the deleted `secondStetOffer(for:in:ledgerText:)` overload
    /// did — this fails at the `XCTUnwrap(offer)` line with "the offer must be
    /// raised over a twin in another chapter": the twin is invisible and the
    /// note simply stets.
    func test_aStettedTwinInAnotherChapterRaisesTheOfferInDocumentScope() async throws {
        let fx = try await makeHarness(named: "TwinAcrossDoc")
        let two = try await makeSecondChapter(fx)
        let twin = try await mintQuestion(in: two, body: "An earlier one of these.")
        try await two.stetAnnotation(id: twin)
        let id = try await mintQuestion(fx)
        XCTAssertTrue(
            fx.document.annotations(filter: AnnotationFilter(statuses: nil))
                .allSatisfy { $0.id != twin },
            "premise: the twin is in the OTHER chapter, invisible to this "
            + "pane's own document")

        let window = mountPane(fx)
        let stet = try button(labelled: "Stet", in: window)
        _ = stet.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.3)

        let raised = try XCTUnwrap(
            offer, "the offer must be raised over a twin in another chapter")
        XCTAssertEqual(raised.heading, "Filter words")
        XCTAssertEqual(raised.annotationId, id)
        XCTAssertEqual(status(fx, id), .open,
                       "and the note waits for the answer")
    }

    /// The same, pressed in **project scope** — the scope whose rows come from
    /// the project walk in the first place, so the two scopes cannot come to
    /// different answers about one habit.
    ///
    /// **Disable experiment.** Same disable as the document-scope case above,
    /// same failure line: with the document-only search this fails at
    /// `XCTUnwrap(offer)`, because the row's own document is chapter one and
    /// the twin is in chapter two.
    func test_aStettedTwinInAnotherChapterRaisesTheOfferInProjectScope() async throws {
        let fx = try await makeHarness(named: "TwinAcrossProject")
        let two = try await makeSecondChapter(fx)
        let twin = try await mintQuestion(in: two, body: "An earlier one of these.")
        try await two.stetAnnotation(id: twin)
        let id = try await mintQuestion(fx)

        let window = mountPane(fx, scope: .project(focusPiece: nil))
        // The stetted twin is resolved, so the default open-only filter leaves
        // exactly one row with a Stet on it: the subject.
        let stet = try button(labelled: "Stet", in: window)
        _ = stet.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.3)

        let raised = try XCTUnwrap(
            offer, "project scope must find the twin too")
        XCTAssertEqual(raised.heading, "Filter words")
        XCTAssertEqual(raised.annotationId, id)
        XCTAssertEqual(status(fx, id), .open)
    }

    // MARK: - Keep as lesson… is withdrawn over a sentence that stands (ruling B)

    /// **A sentence already in the ledger stops being offered** (Denver's
    /// ruling B) — open, a choice, or retired, which is `LessonOffer.keepIsOffered`'s
    /// own rule one door over. Each is the writer having already decided about
    /// exactly this sentence.
    ///
    /// **Identity is exact after trimming** (global constraint 15): the
    /// near-miss below still draws, because the note's body and the standing
    /// heading are then two different sentences and the app does not guess.
    /// Hiding on a near-miss would be worse than the duplicate it prevents —
    /// it would take away the only control that files this note's point.
    ///
    /// **Disable experiment.** With the ledger clause dropped from
    /// `offersAKeep` (the P2 body: kind, status and authorship alone), this
    /// fails on the first standing case at "a sentence standing as a live
    /// lesson is one the writer has already filed" — and, being a pure
    /// predicate over three ledger states, on the other two as well.
    func test_theKeepVerbIsWithdrawnOnceTheSentenceStands() {
        let subject = note(kind: .craftNote, status: .accepted, heading: nil)
        let body = subject.body

        XCTAssertTrue(
            QueueLedgerVerbs.offersAKeep(subject, ledgerText: nil),
            "premise: with nothing kept yet, the door is open")

        let standing: [(String, String)] = [
            ("a sentence standing as a live lesson is one the writer has "
             + "already filed",
             "## Rulings\n\n- \(body) \u{2014} ruled 1 Sep 2026\n"),
            ("a sentence standing as a choice is one they have decided about",
             "## Rulings\n\n- Choice: \(body) \u{2014} ruled 1 Sep 2026\n"),
            ("a retired sentence is one they are done with, and re-offering "
             + "it is the coach forgetting",
             "## Rulings\n\n- \(LessonsLedger.retiredText(body, on: Date())) "
             + "\u{2014} ruled 1 Sep 2026\n"),
        ]
        for (why, text) in standing {
            XCTAssertFalse(
                QueueLedgerVerbs.offersAKeep(subject, ledgerText: text),
                "the keep verb must be withdrawn: \(why)")
        }

        XCTAssertTrue(
            QueueLedgerVerbs.offersAKeep(
                subject,
                ledgerText: "## Rulings\n\n- \(body). \u{2014} ruled 1 Sep 2026\n"),
            "a near-miss \u{2014} one trailing full stop \u{2014} is a "
            + "different sentence, and identity here is exact after trimming "
            + "(global constraint 15). `keepAsLesson`'s find-or-create is what "
            + "guards the duplicate, not a fuzzy match here")
        XCTAssertFalse(
            QueueLedgerVerbs.offersAKeep(
                subject,
                ledgerText: "## Rulings\n\n-   \(body)   \u{2014} ruled 1 Sep 2026\n"),
            "the other side of exact-after-trimming: surrounding whitespace is "
            + "invisible in the file and nothing about the writer's intent "
            + "rides on it, so a padded row still names the same sentence and "
            + "the verb stays withdrawn")
    }

    /// **And the row does not draw it**, mounted, where the writer meets it.
    ///
    /// The near-miss is the control in the same register: one full stop apart,
    /// and the button is back.
    func test_theMountedRowDoesNotDrawKeepOverASentenceThatStands() throws {
        let subject = note(kind: .craftNote, status: .accepted, heading: nil)
        let standing = "## Rulings\n\n- \(subject.body) \u{2014} ruled 1 Sep 2026\n"

        let hidden = try buttonLabels(in: mountRow(subject, ledgerText: standing))
        XCTAssertFalse(
            hidden.contains(QueueLedgerVerbs.keepTitle),
            "a note whose words already stand in the ledger must not carry "
            + "the verb that files them again. Buttons: \(hidden)")

        let nearMiss = "## Rulings\n\n- \(subject.body). \u{2014} ruled 1 Sep 2026\n"
        let drawn = try buttonLabels(in: mountRow(subject, ledgerText: nearMiss))
        XCTAssertTrue(
            drawn.contains(QueueLedgerVerbs.keepTitle),
            "control: one full stop apart is a different sentence and the "
            + "door is open. Buttons: \(drawn)")
    }

    /// **The pane hands its rows the ledger** — the seam the two tests above
    /// cannot cross, since they build the row themselves.
    ///
    /// A real project with the note's own sentence already filed: the writer
    /// turns on resolved notes, and the accepted craft note carries every verb
    /// except the one that would file its words twice.
    ///
    /// **Disable experiment.** With `ledgerText:` dropped from the pane's own
    /// `AnnotationRow(` call (the row's default nil), this fails at "the pane
    /// must hand its rows the ledger" — the row draws Keep as lesson… over a
    /// sentence that stands, which is the wiring gap a predicate test cannot
    /// see.
    func test_theRealPaneWithdrawsKeepOverASentenceThatStands() async throws {
        let fx = try await makeHarness(named: "KeepWithdrawn")
        let sentence = "You reach for a filter verb where the image would carry it."
        let pid = try XCTUnwrap(fx.document.sequence.first)
        let id = try await fx.document.addAnnotation(
            kind: .craftNote, paragraphId: pid, body: sentence,
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Le Guin"),
            reviewPassId: "line", compilerRunId: "run-1", compilerRound: 3)
        try await fx.document.acceptAnnotation(id: id)
        let refusal = await QueueLedgerVerbs.keepAsLesson(
            sentence, from: note(kind: .craftNote, status: .accepted),
            store: fx.store, world: nil)
        XCTAssertNil(refusal, "premise: the sentence is filed: \(refusal ?? "")")
        XCTAssertEqual(LessonsLedger.open(in: ledger(fx) ?? ""), [sentence],
                       "premise: and it stands as a live lesson")

        let window = mountPane(fx)
        let resolved = try control(withHelpContaining: "click to include resolved",
                                   in: window)
        _ = resolved.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.3)

        let labels = try buttonLabels(in: window)
        XCTAssertTrue(labels.contains("Stet"),
                      "premise: the accepted note's row is on screen. "
                      + "Buttons: \(labels)")
        XCTAssertFalse(
            labels.contains(QueueLedgerVerbs.keepTitle),
            "the pane must hand its rows the ledger. Buttons: \(labels)")
    }

    /// **The unfiltered query, pinned where it can regress.** The list the press
    /// hands over has to carry stetted notes, or the twin this predicate is
    /// about is invisible and the offer never appears.
    ///
    /// The pane's source is `listAnnotationsAcrossProject`, which filters
    /// nothing; the trap is the default `[.open]` query one line away from it,
    /// and this asserts both halves against the same twin.
    func test_theProjectSnapshotCarriesAStettedTwinTheDefaultQueryHides() async throws {
        let fx = try await makeHarness(named: "TwinVisibility")
        let twin = try await mintQuestion(fx, body: "An earlier one of these.")
        try await fx.document.stetAnnotation(id: twin)
        let id = try await mintQuestion(fx)
        XCTAssertFalse(
            fx.document.annotations().contains { $0.id == twin },
            "premise: the default query cannot see the twin")

        let all = fx.store.listAnnotationsAcrossProject().annotations
            .map(\.annotation)
        XCTAssertTrue(all.contains { $0.id == twin && $0.status == .stetted },
                      "the project walk filters nothing")
        let subject = try XCTUnwrap(all.first { $0.id == id })
        XCTAssertEqual(
            QueueLedgerVerbs.secondStetOffer(
                for: subject, among: all, ledgerText: ledger(fx)),
            "Filter words",
            "and the offer stands over the list the press actually hands over")
    }

    /// **Which button carries `.cancel` is Denver's ruling, and no behavioural
    /// test can see it** — the alert is drawn by the window server, and the
    /// witness value cannot say which of its arms Escape reaches. So the one
    /// thing that can be asserted is asserted: the role is on Cancel and on
    /// nothing else.
    ///
    /// It matters because the failure is silent and one word wide. With the
    /// role on **Just stet**, Escape settles a note — and a writer who pressed
    /// it to make the dialog go away would find the note gone from their queue
    /// with nothing on screen saying so.
    func test_theCancelRoleIsOnCancelAndNotOnJustStet() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Maugham/Views/AnnotationsPane.swift"),
            encoding: .utf8)
        let lines = source.split(separator: "\n").map(String.init)

        let cancelLines = lines.filter { $0.contains("QueueLedgerVerbs.cancelTitle") }
        XCTAssertEqual(cancelLines.count, 1,
                       "control: the scan found the alert's Cancel button")
        XCTAssertTrue(cancelLines[0].contains("role: .cancel"),
                      "Escape must abandon: got \(cancelLines[0])")

        let justStetLines = lines.filter { $0.contains("QueueLedgerVerbs.justStetTitle") }
        XCTAssertEqual(justStetLines.count, 1,
                       "control: the scan found the alert's Just stet button")
        XCTAssertFalse(
            justStetLines[0].contains("role: .cancel"),
            "Just stet must be pressed on purpose, never reached by Escape: "
            + "got \(justStetLines[0])")
    }

    // MARK: - Filing the same heading twice

    /// **One decision, one row** (fix round 1). `offersAChoice` is a pure
    /// annotation predicate, so two open questions raised under one habit each
    /// draw the verb — and before the guard, pressing both filed the same
    /// decision twice under two dates, which then briefs every later round
    /// twice about one thing.
    ///
    /// The second press is a SUCCESS with nothing written, not a refusal: the
    /// writer's decision is in the ledger, which is the state they asked for.
    func test_twoQuestionsUnderOneHeadingFileOneChoiceRow() async throws {
        let fx = try await makeHarness(named: "TwiceOneHeading")
        let first = try await mintQuestion(fx, body: "One of these.")
        let second = try await mintQuestion(fx, body: "And another.")
        let notes = fx.document.annotations(filter: AnnotationFilter(statuses: nil))

        for id in [first, second] {
            let annotation = try XCTUnwrap(notes.first { $0.id == id })
            let refusal = await QueueLedgerVerbs.makeChoice(
                annotation, in: fx.document, store: fx.store, world: nil,
                undoManager: nil)
            XCTAssertNil(refusal,
                         "neither press refuses \u{2014} got: \(refusal ?? "")")
        }

        XCTAssertEqual(
            choices(fx), ["Filter words"],
            "the heading stands once. A duplicate row briefs every later round "
            + "twice about one decision")
        XCTAssertEqual(status(fx, first), .stetted,
                       "and both notes are still stetted \u{2014} the guard is "
                       + "on the ledger row, never on the note")
        XCTAssertEqual(status(fx, second), .stetted)
    }

    /// The control: two DIFFERENT headings are two decisions and file two rows.
    /// Without it, a `makeChoice` that had stopped filing anything at all would
    /// pass the test above.
    func test_twoDifferentHeadingsFileTwoRows() async throws {
        let fx = try await makeHarness(named: "TwoHeadings")
        let first = try await mintQuestion(fx, body: "One.")
        let second = try await mintQuestion(fx, body: "Two.",
                                            heading: "Fragments")
        let notes = fx.document.annotations(filter: AnnotationFilter(statuses: nil))

        for id in [first, second] {
            let annotation = try XCTUnwrap(notes.first { $0.id == id })
            _ = await QueueLedgerVerbs.makeChoice(
                annotation, in: fx.document, store: fx.store, world: nil,
                undoManager: nil)
        }

        XCTAssertEqual(choices(fx), ["Filter words", "Fragments"],
                       "two decisions, two rows, in the order they were made")
    }

    // MARK: - Keep as lesson…

    /// The second door's own four questions.
    func test_theKeepVerbDrawsOnlyOnAnAcceptedCompilerCraftNote() throws {
        let subject = note(kind: .craftNote, status: .accepted, heading: nil)
        let window = mountRow(subject)
        let subjectLabels = try buttonLabels(in: window)
        XCTAssertTrue(
            subjectLabels.contains(QueueLedgerVerbs.keepTitle),
            "premise: an accepted, compiler-authored craft note is the row "
            + "spec \u{00a7}6's second door is for. Buttons: "
            + "\(subjectLabels)")
        XCTAssertTrue(QueueLedgerVerbs.offersAKeep(subject, ledgerText: nil),
                      "and no heading is needed \u{2014} the sheet is where "
                      + "one is made, out of the note's own words")

        let controls: [(String, Annotation)] = [
            ("still open \u{2014} the writer has not agreed with it yet",
             note(kind: .craftNote, status: .open, heading: nil)),
            ("a person's note \u{2014} not a coach's observation",
             note(kind: .craftNote, status: .accepted, heading: nil, runId: nil)),
            ("a question \u{2014} that door is This is a choice",
             note(kind: .query, status: .accepted, heading: nil)),
        ]
        for (why, annotation) in controls {
            XCTAssertFalse(QueueLedgerVerbs.offersAKeep(annotation, ledgerText: nil),
                           "the keep verb must not be offered: \(why)")
            let control = mountRow(annotation)
            let labels = try buttonLabels(in: control)
            XCTAssertFalse(
                labels.contains(QueueLedgerVerbs.keepTitle),
                "and it must not be drawn: \(why). Buttons: "
                + "\(labels)")
        }
    }

    /// **The writer's edit is what is filed**, not the note's paragraph — which
    /// is the whole reason the sheet is a field rather than a confirmation.
    func test_keepAsLessonFilesTheEditedHeadingAsALiveLesson() async throws {
        let fx = try await makeHarness(named: "KeepLesson")
        let annotation = note(kind: .craftNote, status: .accepted, heading: nil)

        let refusal = await QueueLedgerVerbs.keepAsLesson(
            "Cut the filter verbs.", from: annotation,
            store: fx.store, world: nil)

        XCTAssertNil(refusal, "nothing here should have refused: \(refusal ?? "")")
        XCTAssertEqual(LessonsLedger.open(in: ledger(fx) ?? ""),
                       ["Cut the filter verbs."],
                       "it files as a LIVE lesson, not a choice")
        XCTAssertEqual(choices(fx), [],
                       "control: the two markers are not interchangeable")
    }

    /// A blank heading is refused with nothing written — the belt behind the
    /// sheet's disabled Commit. `RulingPerformer` would not catch this on the
    /// choice path (`Choice: ` is not empty); here it would file the writer's
    /// commitment to nothing.
    func test_aBlankHeadingIsRefusedAndFilesNothing() async throws {
        let fx = try await makeHarness(named: "KeepBlank")
        let refusal = await QueueLedgerVerbs.keepAsLesson(
            "   \n ", from: note(kind: .craftNote, status: .accepted),
            store: fx.store, world: nil)
        XCTAssertNotNil(refusal)
        XCTAssertNil(ledger(fx), "and no ledger was minted for an empty entry")
    }

    /// The sheet's own refusal: with nothing in the field, the commit cannot be
    /// pressed at all. Driven through the same press path as every other
    /// control, so "disabled" is asserted where the writer meets it.
    func test_theSheetRefusesABlankHeadingBeforeTheVerbIsCalled() throws {
        var committed: [String] = []
        let blank = Annotation(
            id: "a9", kind: .craftNote, paragraphId: "3k7p", body: "   ",
            suggestedText: nil, priorText: nil, createdAt: Date(),
            createdBySession: nil, status: .accepted, userResponse: nil,
            resolvedAt: nil, isStale: false)
        let window = TestWindow.mount(
            AnyView(LessonHeadingSheet(annotation: blank,
                                       onCommit: { committed.append($0) },
                                       onCancel: {})),
            size: CGSize(width: 460, height: 320))
        windows.append(window)
        pump()

        // Pressed through the same window-readiness guard as every other
        // control here. No re-press: there is no outcome to wait on, and a
        // negative assertion made after a press that did not land would be
        // the very thing the guard exists to rule out.
        try press("Keep as lesson", in: window)
        pump(0.2)
        XCTAssertEqual(committed, [],
                       "a sheet prefilled with nothing usable must not be "
                       + "committable \u{2014} the refusal belongs where the "
                       + "writer can fix it")
    }

    /// And the control: the same sheet with words in it commits them, trimmed.
    func test_theSheetCommitsTheWriterSentence() throws {
        var committed: [String] = []
        let window = TestWindow.mount(
            AnyView(LessonHeadingSheet(
                annotation: note(kind: .craftNote, status: .accepted),
                onCommit: { committed.append($0) },
                onCancel: {})),
            size: CGSize(width: 460, height: 320))
        windows.append(window)
        pump()

        let commit = try press("Keep as lesson", in: window)
        // The guarded re-press, in the one shape a synchronous test can make
        // it: the closure appends, so an empty list after a second of pumping
        // is a press that reached nothing. Committing twice would append
        // twice, which the assertion below would catch — that is why it is
        // guarded rather than unconditional.
        waitUntil({ !committed.isEmpty }, timeout: 1)
        if committed.isEmpty {
            _ = commit.perform(NSSelectorFromString("accessibilityPerformPress"))
        }
        pump(0.2)
        XCTAssertEqual(
            committed,
            ["You reach for \u{201C}she felt\u{201D} where the image would "
             + "carry it on its own."],
            "the field is prefilled with the note so the writer shortens it "
            + "rather than retyping it")
    }

    // MARK: - The row still fits the column it is drawn in

    /// **A verb added to a row is width the column has to find.**
    ///
    /// `AnnotationsQueueToolbarWidthTests` measures the writer's own open
    /// suggestion; this measures the rows Task 8 made wider — a question
    /// carrying Reply / This is a choice / Stet / Archive / triage, and an
    /// accepted craft note carrying Accept / Keep as lesson… / Reject / Stet /
    /// Archive / triage. A row that cannot compress inflates the whole pane's
    /// layout width and everything in the column is then centred against a
    /// width it has not got — the defect that suite exists for.
    func test_theRowsTheseVerbsWidenStillFitTheColumn() {
        let widths = [CGFloat(UIState.detailColumnWidthRange.lowerBound),
                      CGFloat(UIState.defaultDetailColumnWidth)]
        let rows: [(String, Annotation)] = [
            ("a question carrying This is a choice", note()),
            ("an accepted craft note carrying Keep as lesson\u{2026}",
             note(kind: .craftNote, status: .accepted)),
        ]
        for (what, annotation) in rows {
            let row = AnnotationRow(
                annotation: annotation,
                onAccept: {}, onReject: {}, onArchive: {}, onReply: {},
                onJumpToParagraph: {})
            for width in widths {
                let controller = NSHostingController(rootView: AnyView(row))
                _ = controller.view
                let measured = controller
                    .sizeThatFits(in: CGSize(width: width, height: 4000)).width
                XCTAssertLessThanOrEqual(
                    measured, width + 0.5,
                    "\(what) wants \(measured)pt in a \(width)pt column. "
                    + "`actionRow`'s icon fallbacks exist for exactly this; "
                    + "if this is red the new verb is one control too many.")
            }
        }
    }
}

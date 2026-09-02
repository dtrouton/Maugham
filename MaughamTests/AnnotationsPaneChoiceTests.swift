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

    private func mountPane(_ fx: Harness) -> NSWindow {
        let view = AnnotationsPane(
            document: fx.document,
            store: fx.store,
            documentStore: fx.documentStore,
            scope: .constant(.document),
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

    private func mountRow(_ annotation: Annotation) -> NSWindow {
        let row = AnnotationRow(
            annotation: annotation,
            onAccept: {}, onReject: {}, onArchive: {}, onReply: {},
            onJumpToParagraph: {})
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

    /// Whether any element in the tree carries `text` — how the STET flourish
    /// is read, since it is a `Text` badge rather than a control.
    private func showsText(_ text: String, in window: NSWindow) -> Bool {
        guard let tree = try? axTree(in: window) else { return false }
        return tree.contains { element in
            let value = (axAttribute(element, "accessibilityValue") as? String)
                ?? (axAttribute(element, "accessibilityLabel") as? String) ?? ""
            return value.contains(text)
        }
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

    /// Buttons anywhere in the application's windows — a sheet is its own
    /// window, so the tree under the pane's content view cannot see it.
    private func sheetButton(labelled label: String) -> NSObject? {
        for window in NSApp.windows {
            guard let root = window.contentView else { continue }
            let buttons = axElements(under: root).filter { element in
                (axAttribute(element, "accessibilityRole") as? String) == "AXButton"
            }
            let match = buttons.first { element in
                (axAttribute(element, "accessibilityLabel") as? String) == label
            }
            if let match = match as? NSObject { return match }
        }
        return nil
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

    private func findButton(labelled label: String, in window: NSWindow) -> NSObject? {
        guard let labels = try? axTree(in: window) else { return nil }
        return labels
            .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            .first { (axAttribute($0, "accessibilityLabel") as? String) == label } as? NSObject
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

    /// **The end-to-end pin**: the real pane, the real row, a real press, and
    /// both halves of the act read back where they land — the ledger through
    /// `LessonsLedger`'s grammar, the note through an unfiltered query.
    func test_pressingThisIsAChoiceFilesTheHeadingAndStetsTheNote() async throws {
        let fx = try await makeHarness()
        let id = try await mintQuestion(fx)
        XCTAssertNil(ledger(fx), "premise: nothing has been kept in this project")
        XCTAssertEqual(status(fx, id), .open, "premise: the note is open")

        let window = mountPane(fx)
        let press = try button(labelled: QueueLedgerVerbs.choiceTitle, in: window)
        _ = press.perform(NSSelectorFromString("accessibilityPerformPress"))

        _ = await pumpUntil(deadline: 8) { self.choices(fx) == ["Filter words"] }
        XCTAssertEqual(
            choices(fx), ["Filter words"],
            "the heading must land in the ledger as a CHOICE, read back "
            + "through the grammar production reads")

        _ = await pumpUntil(deadline: 8) { self.status(fx, id) == .stetted }
        XCTAssertEqual(status(fx, id), .stetted,
                       "a choice IS a stet plus a ruling (spec \u{00a7}6) \u{2014} "
                       + "no new Document verb, and the note leaves the queue")
        // **Control for the refusal test below.** A choice that landed wears
        // the STET mark while it settles: what the writer did to the note is
        // the same thing a plain stet does, and a choice that resolved a row
        // with no mark would read as a different verb.
        XCTAssertTrue(
            showsText("let it stand", in: window),
            "a landed choice must wear the stet flourish while the row settles")
    }

    /// **A refusal takes the mark straight back off** (fix round 1). The
    /// flourish says "this note has been let stand"; over a note the ledger
    /// refused, and which is therefore still open, it is the surface lying
    /// about what happened for a full 2.5 seconds.
    func test_aRefusedChoiceTakesTheStetMarkStraightBackOff() async throws {
        let fx = try await makeHarness(named: "ChoiceRefusedMark")
        let id = try await mintQuestion(fx)
        let window = mountPane(fx)

        let fm = FileManager.default
        let original = try XCTUnwrap(
            fm.attributesOfItem(atPath: fx.url.path)[.posixPermissions] as? NSNumber)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fx.url.path)
        defer {
            try? fm.setAttributes([.posixPermissions: original],
                                  ofItemAtPath: fx.url.path)
        }

        let press = try button(labelled: QueueLedgerVerbs.choiceTitle, in: window)
        _ = press.perform(NSSelectorFromString("accessibilityPerformPress"))

        // **The deadline is inside the flourish, and that is the whole test.**
        // 2.5s is how long the mark stays up on a stet that worked; a deadline
        // past it would go green over the buggy version simply by outwaiting
        // the sleep. Measured at 1.5s: the refusal itself lands in well under
        // a tenth of that.
        _ = await pumpUntil(deadline: 1.5) {
            !self.showsText("let it stand", in: window)
        }
        XCTAssertFalse(
            showsText("let it stand", in: window),
            "the stet mark must come off the moment the verb reports a "
            + "refusal, not 2.5s later")
        XCTAssertEqual(status(fx, id), .open, "premise: the note is still open")
        XCTAssertNil(ledger(fx), "premise: the ruling was refused")
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

    /// **A first stet is a plain stet.** The note settles, and no question is
    /// asked — once is a note let stand.
    func test_aFirstStetSettlesTheNoteAndAsksNothing() async throws {
        let fx = try await makeHarness(named: "FirstStet")
        let id = try await mintQuestion(fx)
        let window = mountPane(fx)

        let stet = try button(labelled: "Stet", in: window)
        _ = stet.perform(NSSelectorFromString("accessibilityPerformPress"))

        _ = await pumpUntil(deadline: 8) { self.status(fx, id) == .stetted }
        XCTAssertEqual(status(fx, id), .stetted,
                       "a first stet must settle the note directly")
        XCTAssertNil(
            offer,
            "and it must raise no offer \u{2014} the app never files on its "
            + "own, and it does not ask on the strength of one stet")
        XCTAssertNil(ledger(fx), "nothing reached the ledger")
    }

    /// **A second stet under the same heading asks.** The note stays open and
    /// the ledger is untouched until the writer answers — the app never files
    /// on its own.
    func test_aSecondStetUnderTheSameHeadingRaisesTheOffer() async throws {
        let fx = try await makeHarness(named: "SecondStet")
        let twin = try await mintQuestion(fx, body: "An earlier one of these.")
        try await fx.document.stetAnnotation(id: twin)
        let id = try await mintQuestion(fx)
        XCTAssertEqual(status(fx, twin), .stetted, "premise: a stetted twin exists")

        let window = mountPane(fx)
        let stet = try button(labelled: "Stet", in: window)
        _ = stet.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.2)

        let raised = try XCTUnwrap(offer, "the second stet must raise the offer")
        XCTAssertEqual(raised.heading, "Filter words",
                       "the offer carries the heading verbatim, so what is "
                       + "filed is the entry the round was briefed on")
        XCTAssertEqual(raised.annotationId, id)
        XCTAssertEqual(
            status(fx, id), .open,
            "and the note waits for the answer rather than settling under it")
        XCTAssertNil(ledger(fx), "nothing is filed before the writer answers")

        raised.makeItAChoice()
        _ = await pumpUntil(deadline: 8) { self.choices(fx) == ["Filter words"] }
        XCTAssertEqual(choices(fx), ["Filter words"],
                       "Make it a choice files the heading the offer named")
        _ = await pumpUntil(deadline: 8) { self.status(fx, id) == .stetted }
        XCTAssertEqual(status(fx, id), .stetted, "and stets the note")
        XCTAssertNil(offer, "and the offer is gone once it is answered")
    }

    /// **Just stet is the writer\u{2019}s no, and it still stets.** The offer
    /// interrupted a stet; the least committal way out of it is the stet the
    /// writer already pressed, never nothing at all.
    func test_justStetSettlesTheNoteAndFilesNothing() async throws {
        let fx = try await makeHarness(named: "JustStet")
        let twin = try await mintQuestion(fx, body: "An earlier one of these.")
        try await fx.document.stetAnnotation(id: twin)
        let id = try await mintQuestion(fx)

        let window = mountPane(fx)
        let stet = try button(labelled: "Stet", in: window)
        _ = stet.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.2)
        let raised = try XCTUnwrap(offer, "premise: the offer stands")

        raised.justStet()
        _ = await pumpUntil(deadline: 8) { self.status(fx, id) == .stetted }
        XCTAssertEqual(status(fx, id), .stetted)
        XCTAssertNil(ledger(fx),
                     "and the writer who said no filed nothing")
    }

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

    /// **The unfiltered query, pinned where it can regress.** The document
    /// overload has to look past the default `[.open]` filter, or the twin it
    /// is about is invisible and the offer never appears.
    func test_theDocumentOverloadSeesAStettedTwinTheDefaultQueryHides() async throws {
        let fx = try await makeHarness(named: "TwinVisibility")
        let twin = try await mintQuestion(fx, body: "An earlier one of these.")
        try await fx.document.stetAnnotation(id: twin)
        let id = try await mintQuestion(fx)
        XCTAssertFalse(
            fx.document.annotations().contains { $0.id == twin },
            "premise: the default query cannot see the twin")

        let subject = try XCTUnwrap(
            fx.document.annotations(filter: AnnotationFilter(statuses: nil))
                .first { $0.id == id })
        XCTAssertEqual(
            QueueLedgerVerbs.secondStetOffer(
                for: subject, in: fx.document, ledgerText: ledger(fx)),
            "Filter words",
            "and the overload must see it anyway")
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
        XCTAssertTrue(QueueLedgerVerbs.offersAKeep(subject),
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
            XCTAssertFalse(QueueLedgerVerbs.offersAKeep(annotation),
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

        let commit = try button(labelled: "Keep as lesson", in: window)
        _ = commit.perform(NSSelectorFromString("accessibilityPerformPress"))
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

        let commit = try button(labelled: "Keep as lesson", in: window)
        _ = commit.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.2)
        XCTAssertEqual(
            committed,
            ["You reach for \u{201C}she felt\u{201D} where the image would "
             + "carry it on its own."],
            "the field is prefilled with the note so the writer shortens it "
            + "rather than retyping it")
    }

    /// **The pane's own Keep wiring, end to end** (fix round 1) — the one seam
    /// the tests above did not cross.
    ///
    /// `onKeepAsLesson` defaults to a no-op, so a button wired to nothing draws,
    /// presses and does nothing, silently. This drives the REAL pane: the
    /// resolved filter is turned on the way a writer turns it on, the row's
    /// **Keep as lesson…** is pressed, the sheet it opens is committed, and the
    /// sentence is read back out of the writer's ledger.
    func test_theKeepButtonInTheRealPaneOpensTheSheetAndFiles() async throws {
        let fx = try await makeHarness(named: "KeepEndToEnd")
        let pid = try XCTUnwrap(fx.document.sequence.first)
        let id = try await fx.document.addAnnotation(
            kind: .craftNote, paragraphId: pid,
            body: "You reach for a filter verb where the image would carry it.",
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Le Guin"),
            reviewPassId: "line", compilerRunId: "run-1", compilerRound: 3)
        try await fx.document.acceptAnnotation(id: id)
        XCTAssertEqual(status(fx, id), .accepted, "premise: the writer agreed")

        let window = mountPane(fx)
        // An accepted note is hidden under the default open-only filter, so
        // this is the writer's own way to it.
        let resolved = try control(withHelpContaining: "click to include resolved",
                                   in: window)
        _ = resolved.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.3)

        let keep = try button(labelled: QueueLedgerVerbs.keepTitle, in: window)
        _ = keep.perform(NSSelectorFromString("accessibilityPerformPress"))
        _ = await pumpUntil(deadline: 5) {
            self.sheetButton(labelled: "Keep as lesson") != nil
        }
        let commit = try XCTUnwrap(
            sheetButton(labelled: "Keep as lesson"),
            "the press must open the sheet")

        _ = commit.perform(NSSelectorFromString("accessibilityPerformPress"))
        _ = await pumpUntil(deadline: 8) {
            !LessonsLedger.open(in: self.ledger(fx) ?? "").isEmpty
        }
        XCTAssertEqual(
            LessonsLedger.open(in: ledger(fx) ?? ""),
            ["You reach for a filter verb where the image would carry it."],
            "the sheet's sentence must reach the writer's ledger through the "
            + "pane's own wiring \u{2014} a button wired to the default no-op "
            + "would press and file nothing, silently")
        XCTAssertEqual(status(fx, id), .accepted,
                       "and the note is unchanged: keeping a lesson out of it "
                       + "is a second, separate act")
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

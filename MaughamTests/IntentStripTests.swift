import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import MaughamCore
@testable import Maugham

/// The intent strip (M2 spec §6.1) — the writer's signature line above the
/// prose, Author persona only.
///
/// **The identity invariant this suite exists to hold is ADR 0027 §1**: nothing
/// model-produced renders in the editor or its chrome, and the strip is the one
/// AI-adjacent surface that sits physically above the prose. It is not a
/// counterexample only for as long as its input is the writer's own statement
/// text. That is asserted structurally here (the view takes a `String`, and the
/// one function that produces it reads `ProjectStore.statementText(of:)` and
/// nothing else) rather than left to a comment, because a comment is what the
/// next reader is free to disagree with.
@MainActor
final class IntentStripTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        temp = nil
    }

    // MARK: - Contract 1: the pure line rule

    func test_noStatementIsNoLine() {
        XCTAssertNil(IntentStrip.line(from: nil))
    }

    func test_anEmptyStatementIsNoLine() {
        XCTAssertNil(IntentStrip.line(from: ""))
        XCTAssertNil(IntentStrip.line(from: "   \n\n\t  \n"))
    }

    /// `# Intent` must never become the signature — a writer whose statement
    /// opens with a heading would otherwise see the *filing label* over their
    /// prose instead of what the piece is going for.
    func test_headingLinesAreSkipped() {
        XCTAssertEqual(
            IntentStrip.line(from: "# Intent\n\nA woman walks into the sea."),
            "A woman walks into the sea.")
        XCTAssertEqual(
            IntentStrip.line(from: "### Chapter three\nCold, and unashamed of it."),
            "Cold, and unashamed of it.")
    }

    /// Nothing but headings is nothing to say. The strip is absent rather than
    /// showing an empty bar (contract 2's rule, reached through the line rule).
    func test_aStatementOfOnlyHeadingsIsNoLine() {
        XCTAssertNil(IntentStrip.line(from: "# Intent\n\n## Voice\n\n"))
    }

    /// A `#` that is not at the head of the line is prose, not a heading —
    /// "#3 in the sequence" is a sentence.
    func test_aHashInsideALineIsNotAHeading() {
        XCTAssertEqual(
            IntentStrip.line(from: "Piece #3 is the one that turns."),
            "Piece #3 is the one that turns.")
    }

    func test_theFirstRealLineIsTaken() {
        XCTAssertEqual(
            IntentStrip.line(from: "Plain and unhurried.\nA second line nobody sees."),
            "Plain and unhurried.")
    }

    func test_aShortLineIsNotTruncated() {
        let short = "Grief, told sideways."
        XCTAssertEqual(IntentStrip.line(from: short), short)
        XCTAssertFalse(try XCTUnwrap(IntentStrip.line(from: short)).hasSuffix("…"))
    }

    /// Truncation is on a WORD boundary — a running head that ends mid-word
    /// reads as a rendering bug rather than as a line that continues.
    func test_aLongLineIsTruncatedOnAWordBoundary() throws {
        let long = String(repeating: "wandering ", count: 30)
            .trimmingCharacters(in: .whitespaces)
        let line = try XCTUnwrap(IntentStrip.line(from: long))

        XCTAssertTrue(line.hasSuffix("…"), "a truncated line must say it is truncated")
        XCTAssertLessThanOrEqual(
            line.count, IntentStrip.maximumLength + 1,
            "the ellipsis may exceed the budget by itself and no more")
        let body = String(line.dropLast())
        XCTAssertFalse(body.hasSuffix(" "), "the boundary space rode along with the word")
        XCTAssertTrue(
            long.hasPrefix(body),
            "the truncated text is not a prefix of the writer's line")
        XCTAssertTrue(
            body.split(separator: " ").allSatisfy { $0 == "wandering" },
            "a word was cut in half: \(body)")
    }

    /// A single word longer than the budget still has to be truncated — there
    /// is no boundary to fall back to, and a strip that grew to fit would push
    /// the prose down.
    func test_aSingleUnbrokenWordIsStillTruncated() throws {
        let line = try XCTUnwrap(
            IntentStrip.line(from: String(repeating: "a", count: 200)))
        XCTAssertTrue(line.hasSuffix("…"))
        XCTAssertLessThanOrEqual(line.count, IntentStrip.maximumLength + 1)
    }

    // MARK: - Contract 2: when there is a strip at all

    /// Author only. Asked over the whole product of persona and chrome state
    /// rather than the one path the plan happened to name.
    func test_theStripIsAuthorsAloneAndHidesWithTheChrome() {
        let text = "A woman walks into the sea."
        for persona in Persona.allCases {
            for isNoChromeOn in [false, true] {
                let line = IntentStrip.line(
                    persona: persona, isNoChromeOn: isNoChromeOn, statementText: text)
                let shouldShow = (persona == .author && !isNoChromeOn)
                XCTAssertEqual(
                    line != nil, shouldShow,
                    "persona \(persona), no-chrome \(isNoChromeOn)")
            }
        }
    }

    func test_noIntentIsNoStrip() {
        XCTAssertNil(IntentStrip.line(
            persona: .author, isNoChromeOn: false, statementText: nil))
        XCTAssertNil(IntentStrip.line(
            persona: .author, isNoChromeOn: false, statementText: "# Intent\n"))
    }

    // MARK: - Contract 3: the data path, by construction

    /// The strip's text comes from `statementText(of:)` and from nowhere else.
    ///
    /// A source census rather than a comment (ADR 0027 §1): the view's only
    /// stored input is a `String`, the only function that produces one is
    /// `IntentStrip.line`, and the only production construction of the view is
    /// `ProjectWindow`'s — which passes that function's output. If a future
    /// hand reaches for a diagnostic body, a summary or any other
    /// model-produced string, one of these goes red.
    func test_theOnlyProductionCallerFeedsItStatementText() throws {
        let stripURL = sourceDir.appendingPathComponent("Views/IntentStrip.swift")
        let strip = try code(of: stripURL)

        // Control first: the scan must be able to see this file's code at all,
        // or every assertion below is vacuously true.
        XCTAssertTrue(strip.contains("struct IntentStrip"),
                      "the comment-stripped scan found no code to scan")
        for forbidden in ["Diagnostic", "diagnostic", "Compiler", "runner", "model"] {
            XCTAssertFalse(
                strip.contains(forbidden),
                "`\(forbidden)` reached IntentStrip.swift's CODE — the strip renders "
                + "the writer's own statement text and nothing model-produced "
                + "(ADR 0027 §1)")
        }
        XCTAssertTrue(strip.contains("statementText(of:"),
                      "the resolver stopped reading the statement's own text")

        let constructions = try productionSwiftFiles()
            .filter { $0.lastPathComponent != "IntentStrip.swift" }
            .map { (try code(of: $0), $0.lastPathComponent) }
            .filter { $0.0.contains("IntentStrip(") }
        XCTAssertEqual(
            constructions.map(\.1), ["ProjectWindow.swift"],
            "the strip is constructed somewhere new; that site must feed it "
            + "statement text too")
        XCTAssertTrue(
            try XCTUnwrap(constructions.first).0.contains("IntentStrip.line("),
            "ProjectWindow builds the strip's line some other way than the one "
            + "resolver, so the statement-text path is no longer structural")
    }

    /// **The view's stored inputs are exactly a line and a flag** — the
    /// structural half of ADR 0027 §1 now that the strip draws something the
    /// compiler caused (M3-P3 §7).
    ///
    /// The forbidden-token census above catches a diagnostic *reached for* from
    /// inside this file. It cannot catch the other shape, which is the one a
    /// hurry would take: a model-authored sentence handed IN at the mounting
    /// site — `IntentStrip(line: line, mayTrailDraft: flag, note: run.driftNote)`
    /// — because every token of that lives in `ProjectWindow.swift`. What makes
    /// it impossible is the input list: a sentence needs somewhere to land, and
    /// the only inputs are a `String` the resolver produces from the writer's
    /// own statement and a `Bool`, which cannot carry prose.
    ///
    /// Planted offender below, because a census that cannot be shown to see an
    /// offender is a census that passes for the wrong reason.
    func test_theStripStoresALineAndAFlagAndNothingElse() throws {
        let strip = try code(of: sourceDir.appendingPathComponent("Views/IntentStrip.swift"))

        XCTAssertEqual(
            Self.storedInputs(in: strip),
            [Self.StoredInput(name: "line", type: "String"),
             Self.StoredInput(name: "mayTrailDraft", type: "Bool")],
            "the strip's stored inputs changed. A second `String` is a place for "
            + "model-produced prose to land in the editor's chrome (ADR 0027 §1) "
            + "— the mark's words are `IntentStrip.mayTrailDraftMark`, written "
            + "here and fixed at compile time")

        // The planted offender: the same detector, over the shape this test
        // exists to stop. If this passes silently the assertion above proves
        // nothing.
        let planted = """
            struct IntentStrip: View {
                let line: String
                var mayTrailDraft: Bool = false
                let driftNote: String
                var body: some View { Text(line) }
            }
            """
        XCTAssertEqual(
            Self.storedInputs(in: planted),
            [Self.StoredInput(name: "line", type: "String"),
             Self.StoredInput(name: "mayTrailDraft", type: "Bool"),
             Self.StoredInput(name: "driftNote", type: "String")],
            "the detector cannot see a third input, so the assertion above is "
            + "vacuous")
    }

    private struct StoredInput: Equatable {
        let name: String
        let type: String
    }

    /// Every stored input a view declares: a `let`/`var` member with a written
    /// type, minus `static` (constants of the view's own), `private` (state
    /// nobody hands in) and property wrappers. A local `let x = …` inside a
    /// function has no type annotation and never matches.
    private static func storedInputs(in source: String) -> [StoredInput] {
        source.components(separatedBy: "\n").compactMap { raw -> StoredInput? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("let ") || line.hasPrefix("var ") else { return nil }
            let declaration = line.components(separatedBy: "=")[0]
                .trimmingCharacters(in: .whitespaces)
            guard !declaration.contains("("), !declaration.contains("{") else { return nil }
            let parts = declaration.dropFirst(4).components(separatedBy: ":")
            guard parts.count == 2 else { return nil }
            return StoredInput(
                name: parts[0].trimmingCharacters(in: .whitespaces),
                type: parts[1].trimmingCharacters(in: .whitespaces))
        }
    }

    /// A Swift file's code, with whole-line comments dropped — the census is a
    /// claim about what the file *does*, and a doc comment naming a diagnostic
    /// in order to forbid it must not trip its own rule.
    private func code(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - The piece-first, project-fallback resolution (one spelling)

    func test_thePiecesOwnIntentWinsOverTheProjects() async throws {
        let (_, store, chapter) = try await novelWithChapter(named: "StripPieceFirst")
        try await write("The project's own.", intentFor: .project, in: store)
        try await write("The chapter's own.", intentFor: .document(chapter.id), in: store)

        XCTAssertEqual(
            IntentStrip.line(store: store, docId: chapter.id,
                             persona: .author, isNoChromeOn: false),
            "The chapter's own.")
    }

    func test_aPieceWithNoIntentFallsBackToTheProjects() async throws {
        let (_, store, chapter) = try await novelWithChapter(named: "StripFallback")
        try await write("The project's own.", intentFor: .project, in: store)

        XCTAssertEqual(
            IntentStrip.line(store: store, docId: chapter.id,
                             persona: .author, isNoChromeOn: false),
            "The project's own.")
    }

    func test_neitherScopeHasOneAndThereIsNoStrip() async throws {
        let (_, store, chapter) = try await novelWithChapter(named: "StripNeither")
        XCTAssertNil(IntentStrip.line(store: store, docId: chapter.id,
                                      persona: .author, isNoChromeOn: false))
    }

    /// **One spelling, shared with the compiler.** The strip and
    /// `CompilerEnvironment+Project`'s `intent` closure must not come to
    /// different conclusions about which intent applies to a document — a strip
    /// showing the chapter's intent while the run was briefed on the project's
    /// is a lie about what Claude was told.
    func test_theCompilerAndTheStripResolveTheSameIntent() async throws {
        let (url, store, chapter) = try await novelWithChapter(named: "StripOneSpelling")
        let documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore
        defer { Task { await documentStore.close() } }
        try await write("The project's own.", intentFor: .project, in: store)
        try await write("The chapter's own.", intentFor: .document(chapter.id), in: store)

        let device = DeviceSlug.make(from: "test-mac")
        let environment = CompilerOrchestrator.Environment.production(
            store: store, documentStore: documentStore, projectURL: url,
            declaredWorld: DeclaredWorldStore(projectRoot: url, device: device),
            bible: BibleStore(projectRoot: url, device: device),
            preferences: UserPreferences(), onRunAcknowledged: { _ in })
        let briefed = environment.intent(chapter.id)?.statementText

        let resolved = try XCTUnwrap(store.effectiveIntent(forDocId: chapter.id))
        XCTAssertEqual(briefed, try store.statementText(of: resolved),
                       "the compiler reads a different intent than the strip shows")
        XCTAssertEqual(resolved.scope, .document(chapter.id))
    }

    // MARK: - Contract 6: it updates when the statement does

    /// The strip reads through the statement's **live `Document`** — the same
    /// observed `displayText` the Intent pane binds — so a change made in the
    /// pane is on the strip without a save, a flush or a poll.
    ///
    /// The disk is deliberately untouched here: the assertion would pass off
    /// the derived file too if the text had been flushed, which would prove
    /// nothing about the signal.
    func test_theStripFollowsTheLiveStatementWithNoFlush() async throws {
        let (url, store, chapter) = try await novelWithChapter(named: "StripLive")
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))

        let document = try await Document.load(
            url: url.appendingPathComponent(statement.path),
            device: MacDeviceID.current, session: "strip-test", presenter: nil)
        store.noteStatementDocumentOpened(document, id: statement.id)
        defer {
            store.forgetStatementDocument(id: statement.id)
            Task { await document.close() }
        }

        document.setFullText("First thought.")
        XCTAssertEqual(
            IntentStrip.line(store: store, docId: chapter.id,
                             persona: .author, isNoChromeOn: false),
            "First thought.")

        document.setFullText("Second thought, typed over the first.")
        XCTAssertEqual(
            IntentStrip.line(store: store, docId: chapter.id,
                             persona: .author, isNoChromeOn: false),
            "Second thought, typed over the first.",
            "the strip is showing stale text — it is not reading the live "
            + "Document the Intent pane writes into")
    }

    // MARK: - Contract 4: the click

    /// Pressed, not called. The affordance is what this contract is about, so
    /// the control SwiftUI actually publishes is the thing under test
    /// (`InspectorIntentAffordanceTests`' rule and its reason).
    func test_clickingTheStripAsksForTheIntentPane() async throws {
        let line = "A woman walks into the sea."
        let window = mount(AnyView(IntentStrip(line: line)))

        let notes = await notesPosted(pressing: try button(labelled: line, in: window))

        XCTAssertEqual(notes.count, 1, "the press should post exactly one segment request")
        let note = try XCTUnwrap(notes.first)
        XCTAssertEqual(note.userInfo?[MaughamEvent.detailSegmentKey] as? String,
                       DetailSegment.intent.rawValue)
        XCTAssertTrue(
            MaughamEvent.shouldDeliver(note, to: EventReceiverContext(
                kind: .keyWindow, isWindowLive: true, isWindowKey: true)),
            "the key window's receiver drops the post — it reaches nothing")
        XCTAssertFalse(
            MaughamEvent.shouldDeliver(note, to: EventReceiverContext(
                kind: .keyWindow, isWindowLive: true, isWindowKey: false)),
            "control: a non-key window must not act on it")
    }

    /// **The one accepted divergence between what the strip SHOWS and where the
    /// click LANDS**, pinned so it is a recorded position and not a surprise.
    ///
    /// The strip falls back to the project's intent for a chapter that has none;
    /// the Intent pane's scope follows the binder selection and never falls back
    /// (`StatementPane.effectiveScope`), so the click opens that chapter's empty
    /// editor rather than the project statement whose line was on screen.
    /// Landing on the fallback scope would need Open-sets-scope machinery — the
    /// reverted three-round M1A work — and was refused. If this test ever goes
    /// red because the two agree, the refusal has been revisited and this
    /// comment is the thing to update.
    func test_theClickLandsOnTheBindersScopeEvenWhenTheStripShowedTheProjects()
        async throws
    {
        let (_, store, chapter) = try await novelWithChapter(named: "StripDivergence")
        try await write("The project's own.", intentFor: .project, in: store)

        XCTAssertEqual(
            IntentStrip.line(store: store, docId: chapter.id,
                             persona: .author, isNoChromeOn: false),
            "The project's own.",
            "the strip stopped falling back to the project")
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, subject: .item(chapter.id),
                structure: store.manifest.structure),
            .document(chapter.id),
            "the pane's scope now follows the strip's fallback — Open-sets-scope "
            + "was built after all, and the accepted divergence is gone")
    }

    // MARK: - Contract 7: the quiet mark (M3-P3 §7)

    /// The truth table of the ONE decision, asked over the product of its
    /// inputs rather than down the one path the window takes.
    func test_theMarkIsRaisedOnlyByADriftedVerdictOverAnUntouchedIntent() {
        let intent = "Cold, and never wistful."

        XCTAssertTrue(
            IntentDrift.mayTrailDraft(
                lastRun: Self.runRecord(verdict: "drifted", snapshot: intent),
                currentStatementText: intent),
            "a drifted verdict over the very text it checked is the mark's one case")

        XCTAssertFalse(
            IntentDrift.mayTrailDraft(
                lastRun: Self.runRecord(verdict: "drifted", snapshot: intent),
                currentStatementText: intent + " Warmer at the end."),
            "the writer answered the mark by moving the intent; it must clear")
        XCTAssertFalse(
            IntentDrift.mayTrailDraft(
                lastRun: Self.runRecord(verdict: "holds", snapshot: intent),
                currentStatementText: intent),
            "a later round said the draft holds; the mark is the standing "
            + "round's, not a sticky one")
        XCTAssertFalse(
            IntentDrift.mayTrailDraft(lastRun: nil, currentStatementText: intent),
            "no run has judged this document at all")
        XCTAssertFalse(
            IntentDrift.mayTrailDraft(
                lastRun: Self.runRecord(verdict: nil, snapshot: intent),
                currentStatementText: intent),
            "a run that answered the four sections it knew judged nothing")
        XCTAssertFalse(
            IntentDrift.mayTrailDraft(
                lastRun: Self.runRecord(verdict: "drifted", snapshot: nil),
                currentStatementText: intent),
            "a run with no snapshot checked against nothing this can compare")
        XCTAssertFalse(
            IntentDrift.mayTrailDraft(
                lastRun: Self.runRecord(verdict: "drifted", snapshot: intent),
                currentStatementText: nil),
            "the intent is gone; there is nothing left for the draft to trail")
        XCTAssertFalse(
            IntentDrift.mayTrailDraft(
                lastRun: Self.runRecord(verdict: "wandering", snapshot: intent),
                currentStatementText: intent),
            "a word this build has no glyph for must not raise a mark "
            + "(`DiagnosticIngest` admits two verdicts and nil)")
    }

    /// **The clearing rule end-to-end, through a real statement edit and with
    /// NO further run** — the half a stored mark would get wrong.
    ///
    /// The edit is made through the live `Document` the Intent pane binds, so
    /// this asserts the same signal the window sees: no save, no flush, no
    /// event, and the mark is gone on the next body pass.
    func test_editingTheStatementClearsTheMarkWithNoFurtherRun() async throws {
        let (url, store, chapter) = try await novelWithChapter(named: "StripDriftEdit")
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        let document = try await Document.load(
            url: url.appendingPathComponent(statement.path),
            device: MacDeviceID.current, session: "strip-test", presenter: nil)
        store.noteStatementDocumentOpened(document, id: statement.id)
        defer {
            store.forgetStatementDocument(id: statement.id)
            Task { await document.close() }
        }
        document.setFullText("Cold, and never wistful.\n\n## Rulings\n\n- 2026-08-15: no warmth.")

        // What a run would have snapshotted: the statement WHOLE, through the
        // same reader the compiler's briefing uses.
        let checked = try store.statementText(of: statement)
        let drifted = Self.runRecord(verdict: "drifted", snapshot: checked)

        XCTAssertTrue(
            IntentDrift.mayTrailDraft(store: store, docId: chapter.id, lastRun: drifted),
            "control: the standing run drifted against the intent as it reads now")

        document.setFullText(
            "Cold, and never wistful. Warmer at the end.\n\n## Rulings\n\n- 2026-08-15: no warmth.")

        XCTAssertFalse(
            IntentDrift.mayTrailDraft(store: store, docId: chapter.id, lastRun: drifted),
            "the writer edited the intent and no run has judged the new one — "
            + "the mark is standing over a comparison nobody made")
    }

    /// A document with no intent anywhere raises nothing, whatever the run
    /// said. Absence is valid (M1A's rule) and there is no strip to mark.
    func test_aDocumentWithNoIntentRaisesNoMark() async throws {
        let (_, store, chapter) = try await novelWithChapter(named: "StripDriftNoIntent")
        XCTAssertFalse(IntentDrift.mayTrailDraft(
            store: store, docId: chapter.id,
            lastRun: Self.runRecord(verdict: "drifted", snapshot: "Cold, and never wistful.")))
    }

    /// The mark reaches the screen as the app's own fixed words.
    func test_theMarkedStripDrawsTheAppsOwnWords() throws {
        let line = "A woman walks into the sea."
        let window = mount(AnyView(IntentStrip(line: line, mayTrailDraft: true)))

        let spoken = try axStrings(in: window)
        XCTAssertTrue(
            spoken.contains { $0.contains(IntentStrip.mayTrailDraftMark) },
            "the mark never reached the tree. Found: \(spoken)")
        XCTAssertTrue(
            spoken.contains { $0.contains(line) },
            "control: the writer's own line must still be there")
    }

    /// And it is absent — not dimmed, not empty — when the flag is false, which
    /// is every strip in a project whose last round said nothing about drift.
    func test_anUnmarkedStripDrawsNoTraceOfTheMark() throws {
        let line = "A woman walks into the sea."
        let window = mount(AnyView(IntentStrip(line: line, mayTrailDraft: false)))

        let spoken = try axStrings(in: window)
        XCTAssertFalse(
            spoken.contains { $0.contains(IntentStrip.mayTrailDraftMark) },
            "an unmarked strip is carrying the mark. Found: \(spoken)")
        XCTAssertTrue(
            spoken.contains { $0.contains(line) },
            "control: the strip drew nothing at all, so the assertion above "
            + "could not have failed. Found: \(spoken)")
    }

    /// **The wiring census.** The decision, the flag and the mounting site are
    /// three files; delete the middle one and every assertion above still
    /// passes while no writer ever sees the mark.
    func test_theMarkIsWiredFromTheDecisionToTheOneMountingSite() throws {
        let window = try code(
            of: sourceDir.appendingPathComponent("Views/ProjectWindow.swift"))
        XCTAssertTrue(
            window.contains("IntentDrift.mayTrailDraft("),
            "the window must ask the one decision rather than write a condition "
            + "of its own")
        XCTAssertTrue(
            window.contains("mayTrailDraft: intentStripMayTrailDraft"),
            "the flag reaches the strip nowhere; the mark can never be drawn")
        XCTAssertTrue(
            window.contains("lastRun(docId:"),
            "the decision is being fed something other than the standing run")
    }

    /// A glyph that does not resolve draws nothing at all and says nothing
    /// about itself — the one failure mode of a symbol name that survives
    /// every other assertion here.
    func test_theMarksGlyphIsASymbolThisSystemHas() {
        XCTAssertNotNil(
            NSImage(systemSymbolName: IntentStrip.mayTrailDraftSymbol,
                    accessibilityDescription: nil),
            "\u{201C}\(IntentStrip.mayTrailDraftSymbol)\u{201D} is not an SF Symbol "
            + "this system can draw; the mark would show its words with a hole "
            + "in front of them")
    }

    /// A run record with just enough on it for the drift decision — the fields
    /// this contract reads and no fixture arithmetic beside them.
    private static func runRecord(verdict: String?, snapshot: String?) -> CompilerRun {
        CompilerRun(
            id: "run-1", at: Date(), model: "test-model", lastOpId: "op1",
            deltaSummary: "1 new, 0 revised \u{00b6}", intentSnapshot: snapshot,
            intentDriftVerdict: verdict)
    }

    /// Every string the tree speaks, which is what a writer with VoiceOver
    /// hears and what a sighted writer reads.
    private func axStrings(in window: NSWindow) throws -> [String] {
        try axTree(in: window).flatMap { element in
            ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"]
                .compactMap { axAttribute(element, $0) as? String }
        }
    }

    // MARK: - Contract 5: the register

    /// Footnote size and `.secondary`, matched to `EditorStatusFooter` — the
    /// strip is the running head at the other end of the same page.
    func test_theStripIsSetInTheStatusFootersRegister() {
        XCTAssertEqual(IntentStrip.fontSize, 11,
                       "the strip drifted off the status footer's size")
        XCTAssertLessThan(IntentStrip.restingOpacity, 1.0,
                          "the strip must be dimmer than the prose it sits over")
    }

    // MARK: - Fixtures

    private func novelWithChapter(
        named name: String
    ) async throws -> (URL, ProjectStore, StructureItem) {
        let url = try await ProjectFactory.createNovelProject(named: name, in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        let chapter = try XCTUnwrap(
            store.manifest.structure.first(where: { $0.type == .document }))
        return (url, store, chapter)
    }

    /// Put `text` into the intent for `scope`, through the store's own append
    /// seam — no hand-written file, so the test reads what production writes.
    private func write(
        _ text: String, intentFor scope: Statement.Scope, in store: ProjectStore
    ) async throws {
        let statement = try await store.createStatement(kind: .intent, scope: scope)
        try await store.appendToStatement(text, to: statement, session: "strip-test")
    }

    private var sourceDir: URL {
        let here = URL(fileURLWithPath: #filePath)
        return here.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham", isDirectory: true)
    }

    private func productionSwiftFiles() throws -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourceDir, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    // MARK: - Hosting (mirrors `InspectorIntentAffordanceTests`)

    private func mount(_ view: AnyView) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 720, height: 200)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump()
        return window
    }

    private func pump(_ seconds: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

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
                "no assistive client could be attached to this process "
                + "(AXUIElementCopyAttributeValue -> \(error.rawValue)), so SwiftUI "
                + "never builds the tree this test presses through")
        }
        return axElements(under: try XCTUnwrap(window.contentView))
    }

    private func button(labelled label: String, in window: NSWindow) throws -> NSObject {
        let all = try axTree(in: window)
            .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
        let labels = all.map { axAttribute($0, "accessibilityLabel") as? String ?? "nil" }
        XCTAssertFalse(all.isEmpty,
                       "the hosted strip published no buttons at all, so this test "
                       + "could not fail for the reason it exists")
        return try XCTUnwrap(
            all.first { (axAttribute($0, "accessibilityLabel") as? String) == label }
                as? NSObject,
            "no button labelled \u{201C}\(label)\u{201D} reached the hosted strip. "
            + "Buttons found: \(labels)")
    }

    private func notesPosted(pressing button: NSObject) async -> [Notification] {
        var received: [Notification] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: capture-only observer inspecting the exact scoped Notification the strip posts
            forName: .maughamSetDetailSegment, object: nil, queue: nil
        ) { received.append($0) }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.2)
        try? await Task.sleep(for: .milliseconds(300))
        pump(0.2)
        return received
    }
}

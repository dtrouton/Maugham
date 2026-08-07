import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The loop closes here** (M2 Task 10). The compiler raises a note; the
/// writer answers *"that's deliberate, because…"*; the answer lands in the
/// piece's intent statement, and the next run reads it as the thing the prose
/// is being checked against. Without this the compiler asks the same question
/// every run and the writer's explanation lives nowhere.
///
/// **What is left here after the declared world (Task 4).**
/// `IntentAppendPerformer` is now a shim over `RulingPerformer.rule`, so the
/// performer-level contracts this file used to hold — the op-logged write,
/// mint-when-absent, piece-not-project routing, the empty refusal and the
/// unreadable-destination refusal with its control — have moved to
/// `RulingPerformerTests`, where they are asserted against the verbs that own
/// them rather than through a shim that will be deleted. What stays is what only
/// lives here: that the shim really does route (an answer becomes a *ruling*,
/// not an essay paragraph), and the **pane's** own contracts, which Stage 2
/// rewrites and which nothing else covers.
@MainActor
final class IntentAppendPerformerTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        windows.removeAll()
        temp = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// A loaded novel with its first chapter, and the store the performer
    /// writes through. `wordCountPopulationTask` is awaited so a test asserting
    /// "nothing was written" is not racing `load`'s own tail.
    private func loadedNovel(
        named name: String
    ) async throws -> (url: URL, store: ProjectStore, chapter: StructureItem) {
        let url = try await ProjectFactory.createNovelProject(named: name, in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        let chapter = try XCTUnwrap(
            store.manifest.structure.first, "the novel fixture has no chapter")
        return (url, store, chapter)
    }

    /// Every op ever written into a statement, read back off disk through the
    /// production store. A statement is an ordinary `Document` with an ordinary
    /// op log keyed on its manifest id (`StatementDocIdTests`).
    private func ops(of statement: Statement, in projectURL: URL) async throws -> [Op] {
        try await OpLogStore(projectURL: projectURL).load(docId: statement.id)
    }

    /// What a statement SAYS, derived from its op log alone — never read off
    /// the `.md` beside it, which is derived output (tripwire 20).
    private func derivedText(of statement: Statement, in projectURL: URL) async throws -> String {
        let derived = Deriver.derive(ops: try await ops(of: statement, in: projectURL))
        return derived.sequence.compactMap { derived.paragraphs[$0] }.joined(separator: "\n\n")
    }

    /// Bytes that are not valid UTF-8, so `String(contentsOf:encoding:.utf8)`
    /// throws — the exact call `Document.load` makes with a `try?` and a
    /// silent `?? ""` fallback.
    private static let undecodableBytes = Data([0xFF, 0xFE, 0xFD, 0xFC])

    private func makeDiagnostic(
        docId: String, paragraphId: String?, anchorText: String = "",
        body: String = "The rhythm flattens across these three sentences."
    ) -> Diagnostic {
        Diagnostic(
            id: ULID.generate(), docId: docId,
            anchor: paragraphId.map {
                Diagnostic.Anchor(paragraphId: $0, anchorText: anchorText)
            },
            body: body, category: "rhythm", runId: ULID.generate())
    }

    private func makeRun() -> CompilerRun {
        CompilerRun(
            id: ULID.generate(), at: Date(), model: "sonnet", lastOpId: "op1",
            deltaSummary: "1 new, 0 revised \u{00b6}", intentSnapshot: nil)
    }

    // MARK: - The shim routes (declared-world Task 4)

    /// **The answer is a ruling now, not a paragraph of the essay.** Spec §3.4
    /// names the shipped append as the membrane's loosest point — a chat reply
    /// copied verbatim into the writer's declared intent — and this is the
    /// tightening: the same sentence arrives itemized, dated and carrying where
    /// it came from, under `## Rulings`, leaving the essay the writer wrote
    /// untouched.
    func test_theAnswerBecomesARulingAndNotAnEssayParagraph() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AnswerBecomesRuling")
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        try await store.appendToStatement(
            "A ghost story told in weather.", to: statement, session: "seed")

        let answer = "The repetition is deliberate \u{2014} the fog is a refrain."
        try await IntentAppendPerformer.append(
            answer: answer, forDocId: chapter.id, store: store)

        let parsed = RulingsSection.parse(try await derivedText(of: statement, in: url))
        XCTAssertEqual(
            parsed.essay, "A ghost story told in weather.",
            "the essay is the writer's own prose and an answer must not join it")
        XCTAssertEqual(parsed.rulings.map(\.text), [answer])
        XCTAssertNotNil(
            parsed.rulings.first?.ruledOn,
            "and it carries the day it was ruled \u{2014} an undated decision is the "
            + "thing \u{00a7}3.2 replaced")
        XCTAssertNotNil(parsed.rulings.first?.provenance,
                        "and where it came from")
    }

    /// The shim is a route and nothing else: every refusal it can produce is
    /// `RulingPerformer`'s, asserted there. This pins that it still refuses
    /// rather than swallowing — a shim that returned quietly would dismiss the
    /// note over an answer that went nowhere.
    func test_theShimRefusesThroughTheVerbItRoutesTo() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "AnswerShimRefuses")

        do {
            try await IntentAppendPerformer.append(
                answer: "   \n  ", forDocId: chapter.id, store: store)
            XCTFail("an empty answer must refuse")
        } catch let failure as RulingFailure {
            XCTAssertEqual(failure, .emptyRuling)
        }
        XCTAssertNil(store.statement(kind: .intent, scope: .document(chapter.id)),
                     "and mints nothing to put nothing in")
    }

    // MARK: - The pane's own commit, end to end

    /// **The whole loop in one test**, driven through the exact function the
    /// reply field's `.onSubmit` calls: the answer reaches the intent statement
    /// AND the note leaves the pane. The dismissal is what stops the writer
    /// being asked to answer the same note twice.
    func test_answeringDismissesTheNote() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AnswerDismisses")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        let note = makeDiagnostic(docId: chapter.id, paragraphId: "a1b2",
                                  anchorText: "The fog came in.")
        diagnostics.replace(run: makeRun(), diagnostics: [note], docId: chapter.id)

        let failure = await DiagnosticsPane.commitAnswer(
            "Deliberate \u{2014} the fog is a refrain.", to: note, docId: chapter.id,
            store: store, diagnostics: diagnostics)

        XCTAssertNil(failure, "the commit reported: \(failure ?? "")")
        XCTAssertTrue(
            diagnostics.live(docId: chapter.id, currentText: { _ in "The fog came in." }).isEmpty,
            "an answered note has become intent \u{2014} leaving it on the pane asks the "
            + "writer to answer it twice")
        let statement = try XCTUnwrap(store.statement(kind: .intent, scope: .document(chapter.id)))
        let parsed = RulingsSection.parse(try await derivedText(of: statement, in: url))
        XCTAssertEqual(parsed.rulings.map(\.text), ["Deliberate \u{2014} the fog is a refrain."],
                       "the answer landed as the piece's ruling")
    }

    /// **A refused answer keeps the note AND reports why.** The writer's words
    /// are still in the field they typed them into; dismissing a note whose
    /// answer went nowhere would lose both.
    func test_aRefusedAnswerLeavesTheNoteStanding() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AnswerRefusedKeepsNote")
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        try Self.undecodableBytes.write(to: url.appendingPathComponent(statement.path))
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        let note = makeDiagnostic(docId: chapter.id, paragraphId: "a1b2",
                                  anchorText: "The fog came in.")
        diagnostics.replace(run: makeRun(), diagnostics: [note], docId: chapter.id)

        let failure = await DiagnosticsPane.commitAnswer(
            "Deliberate.", to: note, docId: chapter.id,
            store: store, diagnostics: diagnostics)

        XCTAssertNotNil(failure, "a refusal must reach the writer as a sentence")
        XCTAssertEqual(
            diagnostics.live(docId: chapter.id,
                             currentText: { _ in "The fog came in." }).count, 1,
            "the note stays \u{2014} the answer went nowhere")
    }

    // MARK: - The affordance, on the delivery path

    /// The reply field is revealed by an **Answer** action, and a drift note
    /// never offers one: drift is not about a paragraph, and its action is
    /// Open Intent, where the writer edits the statement directly.
    func test_theReplyFieldNeverRendersForADriftNote() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AnswerDriftHasNone")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        diagnostics.replace(
            run: makeRun(),
            diagnostics: [makeDiagnostic(
                docId: chapter.id, paragraphId: nil,
                body: "The outline promised a scene that never got written.")],
            docId: chapter.id)

        let window = mount(pane(store: store, diagnostics: diagnostics, docId: chapter.id))
        pump(0.2)

        XCTAssertNotNil(findButton(labelled: "Open Intent", in: window),
                        "drift's own action must be there")
        XCTAssertNil(
            findButton(labelled: "Answer", in: window),
            "a drift note has no \u{00b6} to answer against \u{2014} its action is "
            + "Open Intent, and offering both is two doors to one room")
    }

    /// An anchored note offers Answer, and pressing it puts a text field on the
    /// row. Asserted against the real accessibility tree, so the affordance is
    /// one a writer (and VoiceOver) can actually reach.
    func test_answerRevealsAFieldOnAnAnchoredNote() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AnswerRevealsField")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        diagnostics.replace(
            run: makeRun(),
            diagnostics: [makeDiagnostic(docId: chapter.id, paragraphId: "a1b2",
                                         anchorText: "The fog came in.")],
            docId: chapter.id)

        let window = mount(pane(store: store, diagnostics: diagnostics, docId: chapter.id,
                                currentText: { _ in "The fog came in." }))
        pump(0.2)
        XCTAssertTrue(textFields(in: window).isEmpty,
                      "the field is revealed, not standing")

        let answer = try button(labelled: "Answer", in: window)
        _ = answer.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.3)

        XCTAssertFalse(
            textFields(in: window).isEmpty,
            "pressing Answer must put a field on the row \u{2014} otherwise the action "
            + "names something the writer cannot type into")
    }

    /// The pane offers no Answer at all without a store to write through, so a
    /// press can never reach a destination that does not exist.
    func test_withoutAProjectStoreThereIsNoAnswerAction() async throws {
        let (url, _, chapter) = try await loadedNovel(named: "AnswerNoStore")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        diagnostics.replace(
            run: makeRun(),
            diagnostics: [makeDiagnostic(docId: chapter.id, paragraphId: "a1b2",
                                         anchorText: "The fog came in.")],
            docId: chapter.id)

        let window = mount(pane(store: nil, diagnostics: diagnostics, docId: chapter.id,
                                currentText: { _ in "The fog came in." }))
        pump(0.2)

        XCTAssertNil(findButton(labelled: "Answer", in: window))
        XCTAssertNotNil(findButton(labelled: "Promote to Task", in: window),
                        "control: the row itself rendered")
    }

    /// **The wiring the accessibility tree cannot press.** SwiftUI exposes no
    /// way to deliver a Return keystroke into a hosted `TextField`'s editor, so
    /// the two verbs the field's contract turns on — commit on return, escape
    /// cancels — are asserted at the source. Named functions rather than
    /// spelled-out bodies, so a rename fails this rather than a reformat.
    func test_theReplyFieldCommitsOnReturnAndCancelsOnEscape() throws {
        let source = try readSource("Maugham/Views/DiagnosticsPane.swift")
        XCTAssertTrue(
            source.contains(".onSubmit { commit() }"),
            "return must commit the answer \u{2014} a field with no submit verb is a "
            + "box the writer types into and cannot send")
        XCTAssertTrue(
            source.contains(".onExitCommand { cancel() }"),
            "escape must take the field away without writing anything")
        XCTAssertTrue(
            source.contains("Self.commitAnswer("),
            "and the pane must go through the one function the tests above drive \u{2014} "
            + "an append spelled out again at the call site is a path nothing covers")
        XCTAssertTrue(
            source.contains("onAnswer(words)"),
            "the row hands the WORDS up rather than writing them itself; a row that "
            + "reached `IntentAppendPerformer` directly would own the failure state "
            + "the pane is holding for it")
    }

    // MARK: - Hosting + accessibility (mirrors DiagnosticsPaneTests')

    private func pane(
        store: ProjectStore?, diagnostics: DiagnosticsStore, docId: String,
        currentText: @escaping (String) -> String? = { _ in nil }
    ) -> AnyView {
        AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: diagnostics, docId: docId,
            currentText: currentText, compilerModel: .standard, store: store))
    }

    private func mount(_ view: AnyView) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 420, height: 700)
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
                "no assistive client could be attached to this process, so SwiftUI "
                + "never built the tree this test presses through")
        }
        return axElements(under: try XCTUnwrap(window.contentView))
    }

    private func button(labelled label: String, in window: NSWindow) throws -> NSObject {
        var lastAll: [AnyObject] = []
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            lastAll = try axTree(in: window)
                .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            if let match = lastAll.first(
                where: { (axAttribute($0, "accessibilityLabel") as? String) == label }) as? NSObject {
                return match
            }
            pump(0.05)
        }
        return try XCTUnwrap(
            lastAll.first { (axAttribute($0, "accessibilityLabel") as? String) == label } as? NSObject,
            "no button labelled \u{201C}\(label)\u{201D} reached the hosted pane. Found: "
            + "\(lastAll.map { axAttribute($0, "accessibilityLabel") as? String ?? "nil" })")
    }

    /// The non-recording sibling, for a "must NOT be present" assertion —
    /// `button(labelled:in:)`'s `XCTUnwrap` records a failure even through a
    /// caller's `try?` (`DiagnosticsPaneTests` documents the trap).
    private func findButton(labelled label: String, in window: NSWindow) -> NSObject? {
        guard let tree = try? axTree(in: window) else { return nil }
        return tree
            .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            .first { (axAttribute($0, "accessibilityLabel") as? String) == label } as? NSObject
    }

    private func textFields(in window: NSWindow) -> [AnyObject] {
        guard let tree = try? axTree(in: window) else { return [] }
        return tree.filter { (axAttribute($0, "accessibilityRole") as? String) == "AXTextField" }
    }

    private func readSource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath),
                          encoding: .utf8)
    }
}

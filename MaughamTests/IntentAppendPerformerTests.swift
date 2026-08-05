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
/// The performer is the outside writer — `PromotionPerformer`'s shape: validate
/// first, write second, never append to a destination whose current words it
/// could not read. Every assertion below goes through the real op log rather
/// than a returned preview, because the preview can agree with itself and be
/// wrong.
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

    private func fileBytes(of statement: Statement, in projectURL: URL) -> Data? {
        try? Data(contentsOf: projectURL.appendingPathComponent(statement.path))
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

    // MARK: - The answer becomes intent

    /// The headline contract, asserted at the op rather than at the render: an
    /// answer is a real op in the statement's own log whose `next` is the
    /// writer's words. The `.md` beside it is derived and would be a weaker
    /// claim.
    func test_theAnswerBecomesAnIntentParagraph() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AnswerBecomesIntent")
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        try await store.appendToStatement(
            "A ghost story told in weather.", to: statement, session: "seed")

        let answer = "The repetition is deliberate \u{2014} the fog is a refrain."
        try await IntentAppendPerformer.append(
            answer: answer, forDocId: chapter.id, store: store)

        let written = try await ops(of: statement, in: url)
        XCTAssertTrue(
            written.contains { $0.changes.contains { $0.next == answer } },
            "the answer must be an OP in the statement's log, not only a render: "
            + "\(written.flatMap { $0.changes.map(\.next) })")

        let text = try await derivedText(of: statement, in: url)
        XCTAssertTrue(
            text.hasPrefix("A ghost story told in weather."),
            "the intent that was already there must survive an append: \(text)")
        XCTAssertTrue(text.hasSuffix(answer), "the answer lands at the end: \(text)")
    }

    /// One paragraph, not two, and not a rewrite of the one before it.
    func test_theAnswerIsOneNewParagraph() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AnswerIsOneParagraph")
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        try await store.appendToStatement("A ghost story.", to: statement, session: "seed")
        let before = Deriver.derive(ops: try await ops(of: statement, in: url)).sequence

        try await IntentAppendPerformer.append(
            answer: "The fog is a refrain.", forDocId: chapter.id, store: store)

        let after = Deriver.derive(ops: try await ops(of: statement, in: url)).sequence
        XCTAssertEqual(
            after.count, before.count + 1,
            "an answer adds exactly one paragraph to the intent \u{2014} more would be "
            + "the writer's sentence split, fewer would be it swallowing what was there")
        XCTAssertEqual(Array(after.prefix(before.count)), before,
                       "the paragraphs already in the intent keep their ids and order")
    }

    /// No statement yet is the ordinary case for a project that has never had
    /// one: the answer mints it, registers it in the manifest, and is its first
    /// paragraph.
    func test_answerMintsTheStatement() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AnswerMints")
        XCTAssertNil(
            store.statement(kind: .intent, scope: .document(chapter.id)),
            "precondition: nothing has minted this chapter's intent yet")

        let answer = "The chapter is about what the weather will not say."
        try await IntentAppendPerformer.append(
            answer: answer, forDocId: chapter.id, store: store)

        let statement = try XCTUnwrap(
            store.statement(kind: .intent, scope: .document(chapter.id)),
            "the answer must have minted the chapter's intent statement")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: url.appendingPathComponent(statement.path).path),
            "a minted statement has a file at its manifest path")
        let text = try await derivedText(of: statement, in: url)
        XCTAssertEqual(text, answer, "the answer is the statement's first paragraph")

        // Re-read from disk: the manifest entry is durable, not in-memory only.
        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertEqual(
            reloaded.statement(kind: .intent, scope: .document(chapter.id))?.id,
            statement.id,
            "the mint must be saved to the manifest \u{2014} an entry that lives only "
            + "in memory mints a SECOND statement on the next answer")
    }

    // MARK: - Scope: the piece, never the project

    /// **The defect this contract exists against.** A piece-scoped document's
    /// answer written into the project's intent is the M1A craft-intent bug
    /// arriving through a new door: the writer explains one chapter and the
    /// book's statement gains a sentence about it, where every other chapter's
    /// run then reads it.
    ///
    /// `PromotionPerformer.intentScope` deliberately DOES fall back to project
    /// scope, and that difference is the point rather than an inconsistency —
    /// a canvas scrap may carry no piece at all, so a fallback is the only
    /// destination it has. A diagnostic is always raised against an open
    /// manuscript document, so there is always a piece, and a fallback here
    /// would only ever fire on a document that is not in this project — which
    /// must refuse, not redirect.
    func test_scopeIsThePieceNeverTheProject() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AnswerScope")
        let project = try await store.createStatement(kind: .intent, scope: .project)
        try await store.appendToStatement(
            "The book is about weather.", to: project, session: "seed")
        let projectBefore = try await derivedText(of: project, in: url)

        try await IntentAppendPerformer.append(
            answer: "This chapter withholds the ghost.", forDocId: chapter.id, store: store)

        let piece = try XCTUnwrap(store.statement(kind: .intent, scope: .document(chapter.id)))
        let pieceText = try await derivedText(of: piece, in: url)
        let projectAfter = try await derivedText(of: project, in: url)
        XCTAssertEqual(pieceText, "This chapter withholds the ghost.")
        XCTAssertEqual(
            projectAfter, projectBefore,
            "the project's intent must not gain one word from a chapter's answer")
    }

    /// A doc id that names nothing in this project refuses through
    /// `createStatement`'s own guard rather than being redirected anywhere.
    func test_anUnknownDocumentRefusesRatherThanRedirecting() async throws {
        let (url, store, _) = try await loadedNovel(named: "AnswerUnknownDoc")

        do {
            try await IntentAppendPerformer.append(
                answer: "nowhere to put this", forDocId: "doc-nope", store: store)
            XCTFail("an answer for a document this project does not have must refuse")
        } catch let error as ProjectStoreError {
            XCTAssertEqual(error, .structureMissing)
        }

        XCTAssertNil(
            store.statement(kind: .intent, scope: .project),
            "and it must not have fallen back to the project's intent")
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(
                atPath: url.appendingPathComponent("intent").path))?.isEmpty ?? true,
            "nothing was minted")
    }

    // MARK: - Nothing written on a refusal (constitution must #1)

    /// **The destination's own words must be readable before anything is
    /// appended to them.** A statement with no op log has its content in its
    /// bytes, and `Document.load` reads those bytes with
    /// `(try? String(contentsOf:)) ?? ""` — so an undecodable file bootstraps
    /// as EMPTY and the append writes an op whose derived state is the answer
    /// alone. The writer's stated intent would be gone with nothing red.
    func test_unreadableDestinationRefuses() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AnswerUnreadable")
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        let path = url.appendingPathComponent(statement.path)
        try Self.undecodableBytes.write(to: path)
        XCTAssertTrue(
            OpLogStore.opLogFileURLs(forDocId: statement.id, in: url).isEmpty,
            "precondition: these bytes are the only copy of this statement")

        do {
            try await IntentAppendPerformer.append(
                answer: "deliberate, because the fog is a refrain.",
                forDocId: chapter.id, store: store)
            XCTFail("an unreadable destination must refuse")
        } catch let failure as IntentAppendFailure {
            XCTAssertEqual(failure, .unreadableDestination(statement.path))
        }

        XCTAssertEqual(
            fileBytes(of: statement, in: url), Self.undecodableBytes,
            "a refusal writes NOTHING \u{2014} the bytes are the writer's only copy")
        XCTAssertTrue(
            OpLogStore.opLogFileURLs(forDocId: statement.id, in: url).isEmpty,
            "and it must not have opened an op log on the way to refusing")
    }

    /// **The control, and it is what keeps the guard above from being a rule
    /// with a false reason.** When the op log HAS the words, the `.md` is
    /// derived output that the next render rewrites — refusing there would
    /// block the writer over a file Maugham does not read as truth. So the
    /// refusal is scoped exactly to the case where the bytes are the content.
    func test_anUndecodableRenderIsNotARefusalWhenTheOpLogHasTheWords() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AnswerRenderOnly")
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        try await store.appendToStatement(
            "A ghost story told in weather.", to: statement, session: "seed")
        XCTAssertFalse(
            OpLogStore.opLogFileURLs(forDocId: statement.id, in: url).isEmpty,
            "precondition: this statement's words are in its op log")
        try Self.undecodableBytes.write(to: url.appendingPathComponent(statement.path))

        try await IntentAppendPerformer.append(
            answer: "The refrain is deliberate.", forDocId: chapter.id, store: store)

        let text = try await derivedText(of: statement, in: url)
        XCTAssertTrue(text.hasPrefix("A ghost story told in weather."),
                      "the op log's words are still the truth: \(text)")
        XCTAssertTrue(text.hasSuffix("The refrain is deliberate."), text)
    }

    /// An empty answer is refused before anything is minted. Reachable: return
    /// pressed in an untouched field.
    func test_anEmptyAnswerMintsNothing() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "AnswerEmpty")

        do {
            try await IntentAppendPerformer.append(
                answer: "   \n  ", forDocId: chapter.id, store: store)
            XCTFail("an empty answer must refuse")
        } catch let failure as IntentAppendFailure {
            XCTAssertEqual(failure, .emptyAnswer)
        }

        XCTAssertNil(
            store.statement(kind: .intent, scope: .document(chapter.id)),
            "an empty answer must not mint a statement to put nothing in")
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
        let text = try await derivedText(of: statement, in: url)
        XCTAssertEqual(text, "Deliberate \u{2014} the fog is a refrain.")
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

import XCTest
@testable import Maugham
import MaughamCore

/// Adopt is the ONE place a proposal's words reach a statement (spec §10;
/// ADR 0030 §7). It replaces the essay through the ordinary statement write
/// path, keeps the `## Rulings` tail byte-for-byte, appends glossary lines
/// through `RulingPerformer.rule`, creates a missing brief, and is undoable.
@MainActor
final class StatementProposalGateTests: XCTestCase {
    private var temp: TempDirectory!
    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private func loadedNovel() async throws -> (URL, ProjectStore) {
        let url = try await ProjectFactory.createNovelProject(named: "Gate", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return (url, store)
    }

    private func write(_ text: String, into statement: Statement, at projectURL: URL) async throws {
        let document = try await Document.load(
            url: projectURL.appendingPathComponent(statement.path),
            device: "gate-test", session: "s", presenter: nil)
        document.setFullText(text)
        try await document.flushBurstNow()
        await document.close()
    }

    private func proposal(_ kind: ProposableStatement, _ markdown: String,
                          rationale: String? = nil) -> StatementProposalStore.Proposal {
        .init(kind: kind, markdown: markdown, rationale: rationale, proposedAt: Date(), author: "Claude")
    }

    /// Stage, and hand back the proposal as `stage` itself re-reads it from
    /// disk — `.iso8601` has no fractional seconds, so a caller comparing
    /// against `pending(for:)` (as `adopt`'s own guard does) must hold THIS
    /// value, never the one passed in with `Date()`'s sub-second precision
    /// still on it.
    @discardableResult
    private func stage(_ p: StatementProposalStore.Proposal, at url: URL) throws -> StatementProposalStore.Proposal {
        try StatementProposalStore(projectURL: url).stage(p)
    }

    // MARK: - The essay is replaced, the rulings tail is untouched

    func test_adoptReplacesTheEssayAndKeepsTheRulingsTailByteForByte() async throws {
        let (url, store) = try await loadedNovel()
        let brief = try await store.createStatement(kind: .editionBrief("es"), scope: .project)
        let tail = "## Rulings\n\n- ¶k7mq: keep the three ands — ruled 28 Aug 2026, translator's note\n- odd  spacing   kept\n"
        try await write("Old prose.\n\n" + tail, into: brief, at: url)
        // What actually landed, read back through the same door the gate
        // reads through — the op log's own paragraph round trip does not
        // promise to keep a bare trailing blank line, so `before` (and the
        // tail `recomposed` must preserve byte for byte) is derived from
        // what is really on disk, not from the literal handed to `write`.
        let before = try store.statementText(of: brief)
        let actualTail = String(before.dropFirst("Old prose.\n\n".count))

        let p = try stage(proposal(.editionBrief("es"), "New prose, two paragraphs.\n\nSecond."), at: url)
        let adoption = try await StatementProposalGate.adopt(
            p, store: store, world: nil, undoManager: nil, workTaskSink: { _ in })

        let text = try store.statementText(of: brief)
        XCTAssertEqual(text, "New prose, two paragraphs.\n\nSecond.\n\n" + actualTail)
        XCTAssertFalse(adoption.created)
        XCTAssertEqual(adoption.glossaryAppended, 0)
        XCTAssertEqual(adoption.before, before)
        XCTAssertEqual(adoption.after, text)
        XCTAssertNil(StatementProposalStore(projectURL: url).pending(for: .editionBrief("es")),
                     "Adopt clears the slot")
    }

    func test_adoptAppendsTheProposalsGlossaryLinesAsRulingsThroughTheOneDoor() async throws {
        let (url, store) = try await loadedNovel()
        let brief = try await store.createStatement(kind: .editionBrief("es"), scope: .project)
        try await write("Prose.\n\n## Rulings\n\n- existing ruling — ruled 1 Sep 2026, by hand\n", into: brief, at: url)

        let p = try stage(proposal(.editionBrief("es"),
                         "Better prose.\n\n## Rulings\n\n- «October» → «Octubre» (the month, never a name)\n- «Kelly» → «Kelly»\n"), at: url)
        let adoption = try await StatementProposalGate.adopt(
            p, store: store, world: nil, undoManager: nil, workTaskSink: { _ in })
        XCTAssertEqual(adoption.glossaryAppended, 2)

        let parsed = RulingsSection.parse(try store.statementText(of: brief))
        XCTAssertEqual(parsed.essay, "Better prose.")
        XCTAssertEqual(parsed.rulings.map(\.text),
                       ["existing ruling", "«October» → «Octubre» (the month, never a name)", "«Kelly» → «Kelly»"])
        XCTAssertEqual(parsed.rulings[0].provenance, "by hand", "the existing ruling keeps its provenance")
        XCTAssertEqual(parsed.rulings[1].provenance, Ruling.Provenance.glossary)
        XCTAssertEqual(parsed.rulings[1].glossary?.note, "the month, never a name")
    }

    func test_aFirstAdoptOnALanguageWithNoBriefCreatesIt() async throws {
        let (url, store) = try await loadedNovel()
        XCTAssertNil(store.statement(kind: .editionBrief("fr"), scope: .project))
        let p = try stage(proposal(.editionBrief("fr"), "Vous throughout.\n\n## Rulings\n\n- «Kelly» → «Kelly»\n"), at: url)
        let adoption = try await StatementProposalGate.adopt(
            p, store: store, world: nil, undoManager: nil, workTaskSink: { _ in })
        XCTAssertTrue(adoption.created)
        let brief = try XCTUnwrap(store.statement(kind: .editionBrief("fr"), scope: .project))
        let parsed = RulingsSection.parse(try store.statementText(of: brief))
        XCTAssertEqual(parsed.essay, "Vous throughout.")
        XCTAssertEqual(parsed.rulings.map(\.text), ["«Kelly» → «Kelly»"])
    }

    func test_adoptingAVisualLanguageReplacesTheWholeText() async throws {
        let (url, store) = try await loadedNovel()
        let look = try await store.createStatement(kind: .visualLanguage, scope: .project)
        try await write("Old look.\n\n## Rulings\n\n- a heading the writer typed is prose here\n", into: look, at: url)
        let p = try stage(proposal(.visualLanguage, "Serif, generous leading."), at: url)
        _ = try await StatementProposalGate.adopt(p, store: store, world: nil, undoManager: nil, workTaskSink: { _ in })
        XCTAssertEqual(try store.statementText(of: look), "Serif, generous leading.",
                       "visual language has no strata (StatementEssay.carriesRulings), so the whole text is the essay")
    }

    // MARK: - Refusals

    func test_adoptRefusesAnEmptyGlossaryTermEvenIfTheSlotWasHandEdited() async throws {
        let (url, store) = try await loadedNovel()
        // Bypass validation the way a hand-edited slot would.
        let dir = StatementProposalStore.directoryURL(in: url)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = proposal(.editionBrief("es"), "x\n\n## Rulings\n\n- « » → «y»\n")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(p).write(to: StatementProposalStore.fileURL(key: "edition-brief-es", in: url))
        // `p` carries `Date()`, which has fractional seconds; the slot on disk
        // round-trips through `.iso8601` (whole seconds), so `p` itself would
        // never equal what `pending(for:)` reads back. Re-read through the
        // store, exactly as `stage`'s own doc comment says a caller must, so
        // `adopt`'s pending-slot guard sees a match and reaches validation
        // rather than refusing with `.proposalGone`.
        let reread = try XCTUnwrap(StatementProposalStore(projectURL: url).pending(for: .editionBrief("es")))
        do {
            _ = try await StatementProposalGate.adopt(reread, store: store, world: nil, undoManager: nil, workTaskSink: { _ in })
            XCTFail("an empty term must refuse")
        } catch let failure as StatementProposalGate.Failure {
            XCTAssertEqual(failure, .refused(.emptyGlossaryTerm(line: "« » → «y»")))
        }
        XCTAssertNil(store.statement(kind: .editionBrief("es"), scope: .project), "a refused Adopt mints nothing")
    }

    func test_adoptRefusesWhenTheSlotIsGone() async throws {
        let (_, store) = try await loadedNovel()
        let p = proposal(.visualLanguage, "x")
        do {
            _ = try await StatementProposalGate.adopt(p, store: store, world: nil, undoManager: nil, workTaskSink: { _ in })
            XCTFail()
        } catch let failure as StatementProposalGate.Failure {
            XCTAssertEqual(failure, .proposalGone)
        }
    }

    func test_discardClearsTheSlotAndPostsTheEvent() async throws {
        let (url, store) = try await loadedNovel()
        try stage(proposal(.visualLanguage, "x"), at: url)
        var posts = 0
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamStatementProposalsChanged, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        try StatementProposalGate.discard(.visualLanguage, store: store)
        XCTAssertNil(StatementProposalStore(projectURL: url).pending(for: .visualLanguage))
        XCTAssertEqual(posts, 1)
        XCTAssertNil(store.statement(kind: .visualLanguage, scope: .project), "Discard writes nothing")
    }

    // MARK: - Undo

    func test_adoptIsOneUndoStepThatPutsTheOldTextBack() async throws {
        let (url, store) = try await loadedNovel()
        let look = try await store.createStatement(kind: .visualLanguage, scope: .project)
        try await write("Old look.", into: look, at: url)
        let p = try stage(proposal(.visualLanguage, "New look."), at: url)
        let um = UndoManager()
        var tasks: [Task<Void, Never>] = []
        _ = try await StatementProposalGate.adopt(p, store: store, world: nil, undoManager: um,
                                                  workTaskSink: { tasks.append($0) })
        XCTAssertTrue(um.canUndo)
        XCTAssertEqual(um.undoActionName, StatementProposalCopy.undoActionName)
        um.undo()
        for task in tasks { await task.value }
        XCTAssertEqual(try store.statementText(of: look), "Old look.")
        XCTAssertTrue(um.canRedo)
        tasks.removeAll()
        um.redo()
        for task in tasks { await task.value }
        XCTAssertEqual(try store.statementText(of: look), "New look.")
    }

    // MARK: - Copy

    func test_theCopyNamesTheAuthorAndTheStatement() {
        let p = proposal(.editionBrief("es"), "x", rationale: "because")
        // Built from `TranslationReviewIndicator.displayLabel`, not a
        // hardcoded "Spanish": every other test in the suite that names a
        // language does the same, since the label's exact rendering is the
        // function's business, not this test's guess at it.
        let spanishBrief = TranslationReviewIndicator.displayLabel(forLanguageTag: "es") + " edition brief"
        XCTAssertEqual(StatementProposalCopy.bannerTitle(p), "Claude proposed a \(spanishBrief)")
        XCTAssertEqual(StatementProposalCopy.bannerTitle(proposal(.visualLanguage, "x")),
                       "Claude proposed a visual language")
        XCTAssertEqual(StatementProposalCopy.adoptedLine(glossary: 0), "Adopted.")
        XCTAssertEqual(StatementProposalCopy.adoptedLine(glossary: 1), "Adopted, with 1 glossary entry.")
        XCTAssertEqual(StatementProposalCopy.adoptedLine(glossary: 3), "Adopted, with 3 glossary entries.")
        XCTAssertNil(StatementProposalCopy.glossaryLine(count: 0))
        XCTAssertEqual(StatementProposalCopy.glossaryLine(count: 2),
                       "Carries 2 glossary entries, appended as rulings on Adopt.")
        XCTAssertEqual(StatementProposalCopy.firstAdoptCreatesLine(.editionBrief("es")),
                       "There is no \(spanishBrief) yet — Adopt creates it.")
        let now = Date()
        XCTAssertEqual(StatementProposalCopy.bannerWhen(now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(StatementProposalCopy.bannerWhen(now.addingTimeInterval(-720), now: now), "12 minutes ago")
        XCTAssertEqual(StatementProposalCopy.bannerWhen(now.addingTimeInterval(-2 * 86_400 - 5), now: now), "2 days ago")
    }
}

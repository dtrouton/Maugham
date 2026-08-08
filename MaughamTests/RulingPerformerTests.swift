import XCTest
import MaughamCore
@testable import Maugham

/// **The only door into the writer-owned layer** (declared-world Task 4).
///
/// Spec §3.4's membrane: nothing enters a statement except through *rule* /
/// *revoke* / *edit* — or the writer's own typing in the pane. Claude's
/// readings live in caches that decay, and the last test in this file is the
/// census that says no verb here can be handed one.
///
/// Every assertion goes through the real op log or the real derived `.md`
/// rather than a returned preview, for the M2 answer suite's reason: a preview
/// can agree with itself and be wrong.
@MainActor
final class RulingPerformerTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

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

    private func ops(of statement: Statement, in projectURL: URL) async throws -> [Op] {
        try await OpLogStore(projectURL: projectURL).load(docId: statement.id)
    }

    /// What a statement SAYS, derived from its op log alone — never read off the
    /// `.md` beside it as truth (tripwire 20).
    private func derivedText(of statement: Statement, in projectURL: URL) async throws -> String {
        let derived = Deriver.derive(ops: try await ops(of: statement, in: projectURL))
        return derived.sequence.compactMap { derived.paragraphs[$0] }.joined(separator: "\n\n")
    }

    /// The rendered `.md` — read as OUTPUT, which is the one thing a derived
    /// file may be asked about (ADR 0018/0019).
    private func renderedFile(of statement: Statement, in projectURL: URL) throws -> String {
        try String(  // adr-0018-ok: asserting the RENDER, never reading it as truth
            contentsOf: projectURL.appendingPathComponent(statement.path), encoding: .utf8)
    }

    private func fileBytes(of statement: Statement, in projectURL: URL) -> Data? {
        try? Data(contentsOf: projectURL.appendingPathComponent(statement.path))
    }

    private static let undecodableBytes = Data([0xFF, 0xFE, 0xFD, 0xFC])

    private func world(at projectURL: URL) -> DeclaredWorldStore {
        DeclaredWorldStore(projectRoot: projectURL, device: DeviceSlug.make(from: "test-mac"))
    }

    private func seededDerivation(sourceHash: String) -> DerivedWorld {
        DerivedWorld(
            sourceHash: sourceHash,
            clauses: [DerivedClause(quote: "A ghost story.", check: "keep the ghost offstage")],
            rules: [], derivedAt: Date())
    }

    // MARK: - rule

    /// The headline contract, asserted at the op rather than at the render: a
    /// ruling is a real op in the statement's own log.
    func test_aRulingIsOneOpInTheStatementsLog() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "RuleIsAnOp")
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        try await store.appendToStatement(
            "A ghost story told in weather.", to: statement, session: "seed")
        let before = try await ops(of: statement, in: url).count

        try await RulingPerformer.rule(
            "Kelly never lies about the weather.", provenance: "from a run on \u{00b6}wnse",
            forScope: .document(chapter.id), store: store, world: nil)

        let after = try await ops(of: statement, in: url)
        XCTAssertEqual(
            after.count, before + 1,
            "a ruling is exactly ONE op \u{2014} two would be two things to reverse for "
            + "one act (\u{2318}Z is not wired to either yet; see the type doc)")
        XCTAssertTrue(
            after.last?.changes.contains { $0.next.contains("Kelly never lies about the weather.") }
                ?? false,
            "the ruling's words must be in the op: "
            + "\(after.last?.changes.map(\.next) ?? [])")
    }

    /// The rendered file gains exactly the rendered line, and the essay above it
    /// is not touched by one byte.
    func test_theRenderGainsExactlyTheLineAndTheEssayIsUntouched() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "RuleRenders")
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        try await store.appendToStatement(
            "A ghost story told in weather.", to: statement, session: "seed")

        try await RulingPerformer.rule(
            "Kelly heard about the call offstage.", provenance: "from a run on \u{00b6}wnse",
            forScope: .document(chapter.id), store: store, world: nil)

        let rendered = try renderedFile(of: statement, in: url)
        let parsed = RulingsSection.parse(rendered)
        XCTAssertEqual(
            parsed.essay, "A ghost story told in weather.",
            "the essay is the writer's prose and a ruling must not disturb it: \(rendered)")
        XCTAssertEqual(parsed.rulings.count, 1, rendered)
        XCTAssertEqual(parsed.rulings.first?.text, "Kelly heard about the call offstage.")
        XCTAssertEqual(parsed.rulings.first?.provenance, "from a run on \u{00b6}wnse")
        let ruledOn = try XCTUnwrap(parsed.rulings.first?.ruledOn,
                                    "a ruling carries the day it was ruled")
        XCTAssertLessThan(abs(ruledOn.timeIntervalSinceNow), 60 * 60 * 48,
                          "the ruling is dated today")
        XCTAssertEqual(
            rendered.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count, 1,
            "exactly one list item: \(rendered)")
    }

    /// The second ruling joins the section rather than minting a second one.
    func test_aSecondRulingJoinsTheSameSection() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "RuleTwice")

        try await RulingPerformer.rule(
            "Kelly never lies.", provenance: "ruled at the desk",
            forScope: .document(chapter.id), store: store, world: nil)
        try await RulingPerformer.rule(
            "The fog is a refrain.", provenance: "ruled at the desk",
            forScope: .document(chapter.id), store: store, world: nil)

        let statement = try XCTUnwrap(
            store.statement(kind: .intent, scope: .document(chapter.id)))
        let rendered = try renderedFile(of: statement, in: url)
        XCTAssertEqual(
            rendered.components(separatedBy: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces) == RulingsSection.heading }.count,
            1, "one section, not one per ruling: \(rendered)")
        XCTAssertEqual(
            RulingsSection.parse(rendered).rulings.map(\.text),
            ["Kelly never lies.", "The fog is a refrain."],
            "in the order they were ruled")
    }

    /// No statement yet is the ordinary case: the ruling mints it, and the mint
    /// is durable in the manifest rather than in memory only.
    func test_aRulingMintsTheStatementWhenAbsent() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "RuleMints")
        XCTAssertNil(store.statement(kind: .intent, scope: .document(chapter.id)),
                     "precondition: nothing has minted this chapter's intent yet")

        try await RulingPerformer.rule(
            "Kelly never lies.", provenance: "ruled at the desk",
            forScope: .document(chapter.id), store: store, world: nil)

        let statement = try XCTUnwrap(
            store.statement(kind: .intent, scope: .document(chapter.id)),
            "the ruling must have minted the chapter's intent statement")
        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertEqual(
            reloaded.statement(kind: .intent, scope: .document(chapter.id))?.id, statement.id,
            "the mint must reach the manifest \u{2014} an in-memory entry mints a SECOND "
            + "statement on the next ruling")
        XCTAssertEqual(
            RulingsSection.parse(try renderedFile(of: statement, in: url)).essay, "",
            "a minted statement's essay is still empty \u{2014} a ruling is not an essay")
    }

    // MARK: - Scope: the piece, never the project

    /// A piece's ruling written into the book's statement is the M1A
    /// craft-intent defect arriving through a new door: one chapter's decision
    /// read by every other chapter's run.
    func test_scopeIsThePieceNeverTheProject() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "RuleScope")
        let project = try await store.createStatement(kind: .intent, scope: .project)
        try await store.appendToStatement(
            "The book is about weather.", to: project, session: "seed")
        let projectBefore = try await derivedText(of: project, in: url)

        try await RulingPerformer.rule(
            "This chapter withholds the ghost.", provenance: "ruled at the desk",
            forScope: .document(chapter.id), store: store, world: nil)

        let projectAfter = try await derivedText(of: project, in: url)
        XCTAssertEqual(
            projectAfter, projectBefore,
            "the project's intent must not gain one word from a chapter's ruling")
    }

    /// A doc id that names nothing in this project refuses through
    /// `createStatement`'s own guard rather than being redirected anywhere.
    func test_anUnknownDocumentRefusesRatherThanRedirecting() async throws {
        let (url, store, _) = try await loadedNovel(named: "RuleUnknownDoc")

        do {
            try await RulingPerformer.rule(
                "nowhere to put this", provenance: "ruled at the desk",
                forScope: .document("doc-nope"), store: store, world: nil)
            XCTFail("a ruling for a document this project does not have must refuse")
        } catch let error as ProjectStoreError {
            XCTAssertEqual(error, .structureMissing)
        }

        XCTAssertNil(store.statement(kind: .intent, scope: .project),
                     "and it must not have fallen back to the project's intent")
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(
                atPath: url.appendingPathComponent("intent").path))?.isEmpty ?? true,
            "nothing was minted")
    }

    // MARK: - Nothing written on a refusal (constitution must #1)

    func test_anEmptyRulingMintsNothing() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "RuleEmpty")

        do {
            try await RulingPerformer.rule(
                "   \n  ", provenance: "ruled at the desk",
                forScope: .document(chapter.id), store: store, world: nil)
            XCTFail("an empty ruling must refuse")
        } catch let failure as RulingFailure {
            XCTAssertEqual(failure, .emptyRuling)
        }

        XCTAssertNil(store.statement(kind: .intent, scope: .document(chapter.id)),
                     "an empty ruling must not mint a statement to put nothing in")
    }

    /// **The destination's own words must be readable before anything is
    /// written over them.** A statement with no op log has its content in its
    /// BYTES, and `Document.load` reads them with a `try?` and a silent `?? ""`
    /// — so an undecodable file bootstraps EMPTY, the write lands, and the
    /// writer's stated intent is gone with nothing red.
    func test_unreadableDestinationRefuses() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "RuleUnreadable")
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        try Self.undecodableBytes.write(to: url.appendingPathComponent(statement.path))
        XCTAssertTrue(
            OpLogStore.opLogFileURLs(forDocId: statement.id, in: url).isEmpty,
            "precondition: these bytes are the only copy of this statement")

        do {
            try await RulingPerformer.rule(
                "Kelly never lies.", provenance: "ruled at the desk",
                forScope: .document(chapter.id), store: store, world: nil)
            XCTFail("an unreadable destination must refuse")
        } catch let failure as RulingFailure {
            XCTAssertEqual(failure, .unreadableDestination(statement.path))
        }

        XCTAssertEqual(
            fileBytes(of: statement, in: url), Self.undecodableBytes,
            "a refusal writes NOTHING \u{2014} the bytes are the writer's only copy")
        XCTAssertTrue(
            OpLogStore.opLogFileURLs(forDocId: statement.id, in: url).isEmpty,
            "and it must not have opened an op log on the way to refusing")
    }

    /// **The control that keeps the guard above from being a rule with a false
    /// reason.** When the op log HAS the words the `.md` is derived output the
    /// next render rewrites; refusing there would block the writer over a file
    /// Maugham does not read as truth.
    func test_anUndecodableRenderIsNotARefusalWhenTheOpLogHasTheWords() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "RuleRenderOnly")
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        try await store.appendToStatement(
            "A ghost story told in weather.", to: statement, session: "seed")
        XCTAssertFalse(OpLogStore.opLogFileURLs(forDocId: statement.id, in: url).isEmpty,
                       "precondition: this statement's words are in its op log")
        try Self.undecodableBytes.write(to: url.appendingPathComponent(statement.path))

        try await RulingPerformer.rule(
            "Kelly never lies.", provenance: "ruled at the desk",
            forScope: .document(chapter.id), store: store, world: nil)

        let text = try await derivedText(of: statement, in: url)
        XCTAssertTrue(text.hasPrefix("A ghost story told in weather."),
                      "the op log's words are still the truth: \(text)")
        XCTAssertTrue(text.contains("Kelly never lies."), text)
    }

    // MARK: - revoke

    func test_revokeRemovesExactlyTheLine() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "Revoke")
        try await RulingPerformer.rule(
            "Kelly never lies.", provenance: "ruled at the desk",
            forScope: .document(chapter.id), store: store, world: nil)
        try await RulingPerformer.rule(
            "The fog is a refrain.", provenance: "ruled at the desk",
            forScope: .document(chapter.id), store: store, world: nil)
        let statement = try XCTUnwrap(
            store.statement(kind: .intent, scope: .document(chapter.id)))
        let doomed = try XCTUnwrap(
            RulingsSection.parse(try renderedFile(of: statement, in: url)).rulings.first)

        try await RulingPerformer.revoke(
            rulingId: doomed.id, forScope: .document(chapter.id), store: store, world: nil)

        XCTAssertEqual(
            RulingsSection.parse(try renderedFile(of: statement, in: url)).rulings.map(\.text),
            ["The fog is a refrain."],
            "exactly the revoked line leaves; its neighbour stays")
    }

    /// The last ruling's revocation leaves an essay-only file, not a dangling
    /// heading over nothing.
    func test_revokingTheLastRulingLeavesNoDanglingHeading() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "RevokeLast")
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        try await store.appendToStatement("A ghost story.", to: statement, session: "seed")
        try await RulingPerformer.rule(
            "Kelly never lies.", provenance: "ruled at the desk",
            forScope: .document(chapter.id), store: store, world: nil)
        let only = try XCTUnwrap(
            RulingsSection.parse(try renderedFile(of: statement, in: url)).rulings.first)

        try await RulingPerformer.revoke(
            rulingId: only.id, forScope: .document(chapter.id), store: store, world: nil)

        let rendered = try renderedFile(of: statement, in: url)
        XCTAssertFalse(rendered.contains(RulingsSection.heading),
                       "no dangling section over nothing: \(rendered)")
        XCTAssertEqual(RulingsSection.parse(rendered).essay.trimmingCharacters(
            in: .whitespacesAndNewlines), "A ghost story.",
            "and the essay survives the last revocation: \(rendered)")
    }

    /// **Loud, not silent.** `RulingsSection.removing` no-ops on an unknown id;
    /// a performer that passed that through would report success for a
    /// revocation that never happened.
    func test_revokingAnUnknownRulingRefusesAndWritesNothing() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "RevokeUnknown")
        try await RulingPerformer.rule(
            "Kelly never lies.", provenance: "ruled at the desk",
            forScope: .document(chapter.id), store: store, world: nil)
        let statement = try XCTUnwrap(
            store.statement(kind: .intent, scope: .document(chapter.id)))
        let before = try await ops(of: statement, in: url).count

        do {
            try await RulingPerformer.revoke(
                rulingId: "not-a-ruling", forScope: .document(chapter.id),
                store: store, world: nil)
            XCTFail("revoking an id the statement does not carry must refuse")
        } catch let failure as RulingFailure {
            XCTAssertEqual(failure, .unknownRuling("not-a-ruling"))
        }

        let afterRefusal = try await ops(of: statement, in: url).count
        XCTAssertEqual(afterRefusal, before, "a refused revocation writes no op")
        XCTAssertEqual(
            RulingsSection.parse(try renderedFile(of: statement, in: url)).rulings.count, 1,
            "and takes nothing with it")
    }

    /// A scope with no statement at all has nothing to revoke — and must not
    /// mint one on the way to finding that out.
    func test_revokingAgainstNoStatementRefusesAndMintsNothing() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "RevokeNoStatement")

        do {
            try await RulingPerformer.revoke(
                rulingId: "anything", forScope: .document(chapter.id), store: store, world: nil)
            XCTFail("there is nothing to revoke")
        } catch let failure as RulingFailure {
            XCTAssertEqual(failure, .noStatement)
        }
        XCTAssertNil(store.statement(kind: .intent, scope: .document(chapter.id)),
                     "a revocation must not mint the statement it failed to find")
    }

    // MARK: - edit

    /// **Exactly one op, carrying its own prior text** — and that is all this
    /// proves, deliberately.
    ///
    /// The name used to say *one undo step*, which was a claim about ⌘Z that
    /// nothing here drives and nothing in the app delivers: a ruling write arms
    /// no `_undoCoherentApplyPending` and registers no inverse, so the keystroke
    /// reaches it through neither the op log nor the pane's native stack (the
    /// registration is Task 6's; `RulingPerformer`'s type doc has the whole
    /// finding). A test captioned as proving more than it proves is the
    /// prose-count defect wearing a test's clothes.
    ///
    /// What it does hold is the **precondition**, and it is worth holding on its
    /// own: the remove and the re-render are one whole-text transform, so there
    /// is one op with the whole correction's `prior` in it for an inverse to
    /// reverse. Two ops would already have cost the writer two presses for one
    /// act, and no later task could fix that from the outside (ADR 0023).
    func test_anEditIsExactlyOneOpCarryingItsPriorText() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "EditOneStep")
        try await RulingPerformer.rule(
            "Kelly never lys.", provenance: "ruled at the desk",
            forScope: .document(chapter.id), store: store, world: nil)
        let statement = try XCTUnwrap(
            store.statement(kind: .intent, scope: .document(chapter.id)))
        let renderedBefore = try renderedFile(of: statement, in: url)
        let target = try XCTUnwrap(RulingsSection.parse(renderedBefore).rulings.first)
        let opsBefore = try await ops(of: statement, in: url)

        try await RulingPerformer.edit(
            rulingId: target.id, newText: "Kelly never lies.",
            forScope: .document(chapter.id), store: store, world: nil)

        let opsAfter = try await ops(of: statement, in: url)
        XCTAssertEqual(
            opsAfter.count, opsBefore.count + 1,
            "an edit is ONE op \u{2014} a remove op plus an append op would be two "
            + "things to reverse for one correction, and no undo wiring added later "
            + "could merge them back")
        let restored = try XCTUnwrap(opsAfter.last?.changes.first?.prior)
        XCTAssertTrue(
            restored.contains("Kelly never lys."),
            "and that one op carries the PRIOR text, which is what an inverse would "
            + "be built from \u{2014} nothing here presses \u{2318}Z, because nothing "
            + "registers one yet: \(restored)")
    }

    /// An edit is a correction to a decision already made, not a new decision:
    /// the line keeps its place in the list and the day it was ruled.
    func test_anEditKeepsTheRulingWhereItWasAndKeepsItsDate() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "EditInPlace")
        for text in ["First ruling.", "Second rulng.", "Third ruling."] {
            try await RulingPerformer.rule(
                text, provenance: "ruled at the desk",
                forScope: .document(chapter.id), store: store, world: nil)
        }
        let statement = try XCTUnwrap(
            store.statement(kind: .intent, scope: .document(chapter.id)))
        let before = RulingsSection.parse(try renderedFile(of: statement, in: url)).rulings
        let target = before[1]

        try await RulingPerformer.edit(
            rulingId: target.id, newText: "Second ruling.",
            forScope: .document(chapter.id), store: store, world: nil)

        let after = RulingsSection.parse(try renderedFile(of: statement, in: url)).rulings
        XCTAssertEqual(
            after.map(\.text), ["First ruling.", "Second ruling.", "Third ruling."],
            "a corrected ruling stays where the writer put it \u{2014} a remove-then-append "
            + "would send it to the bottom of their list")
        XCTAssertEqual(after[1].provenance, target.provenance,
                       "the provenance of the decision is unchanged by a correction")
        XCTAssertEqual(after[1].ruledOn, target.ruledOn,
                       "and so is the day it was ruled")
    }

    func test_editingAnUnknownRulingRefusesAndWritesNothing() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "EditUnknown")
        try await RulingPerformer.rule(
            "Kelly never lies.", provenance: "ruled at the desk",
            forScope: .document(chapter.id), store: store, world: nil)
        let statement = try XCTUnwrap(
            store.statement(kind: .intent, scope: .document(chapter.id)))
        let before = try await ops(of: statement, in: url).count

        do {
            try await RulingPerformer.edit(
                rulingId: "not-a-ruling", newText: "something else",
                forScope: .document(chapter.id), store: store, world: nil)
            XCTFail("editing an id the statement does not carry must refuse")
        } catch let failure as RulingFailure {
            XCTAssertEqual(failure, .unknownRuling("not-a-ruling"))
        }
        let afterRefusal = try await ops(of: statement, in: url).count
        XCTAssertEqual(afterRefusal, before, "a refused edit writes no op")
    }

    func test_editingToAnEmptyRulingRefuses() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "EditEmpty")
        try await RulingPerformer.rule(
            "Kelly never lies.", provenance: "ruled at the desk",
            forScope: .document(chapter.id), store: store, world: nil)
        let statement = try XCTUnwrap(
            store.statement(kind: .intent, scope: .document(chapter.id)))
        let target = try XCTUnwrap(
            RulingsSection.parse(try renderedFile(of: statement, in: url)).rulings.first)

        do {
            try await RulingPerformer.edit(
                rulingId: target.id, newText: "  ",
                forScope: .document(chapter.id), store: store, world: nil)
            XCTFail("an edit that empties a ruling is a revocation wearing the wrong verb")
        } catch let failure as RulingFailure {
            XCTAssertEqual(failure, .emptyRuling)
        }
        XCTAssertEqual(
            RulingsSection.parse(try renderedFile(of: statement, in: url)).rulings.count, 1)
    }

    // MARK: - The derivation cache can never outlive the prose it read

    /// Every mutation drops the reading for its scope. A cache that survived a
    /// ruling would check the writer against a world they have just changed —
    /// and a revoked rule would keep firing.
    func test_aRulingInvalidatesTheDerivation() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "RuleInvalidates")
        let declared = world(at: url)
        let scope = Statement.Scope.document(chapter.id)
        let key = DeclaredWorldStore.scopeKey(for: scope)
        let hash = DerivedWorld.sourceHash(of: "A ghost story.")
        declared.store(seededDerivation(sourceHash: hash), forScopeKey: key)
        XCTAssertNotNil(declared.cached(forScopeKey: key, sourceHash: hash),
                        "precondition: there is a reading to lose")
        let versionBefore = declared.version

        try await RulingPerformer.rule(
            "Kelly never lies.", provenance: "ruled at the desk",
            forScope: scope, store: store, world: declared)

        XCTAssertNil(
            declared.cached(forScopeKey: key, sourceHash: hash),
            "the reading was made from prose that has just moved \u{2014} serving it "
            + "would check the writer against a world they changed")
        XCTAssertGreaterThan(declared.version, versionBefore,
                             "and the pane must be told, or it draws the dead reading")
    }

    func test_revokingInvalidatesTheDerivation() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "RevokeInvalidates")
        let declared = world(at: url)
        let scope = Statement.Scope.document(chapter.id)
        let key = DeclaredWorldStore.scopeKey(for: scope)
        try await RulingPerformer.rule(
            "Kelly never lies.", provenance: "ruled at the desk",
            forScope: scope, store: store, world: nil)
        let statement = try XCTUnwrap(store.statement(kind: .intent, scope: scope))
        let only = try XCTUnwrap(
            RulingsSection.parse(try renderedFile(of: statement, in: url)).rulings.first)
        let hash = DerivedWorld.sourceHash(of: "seeded")
        declared.store(seededDerivation(sourceHash: hash), forScopeKey: key)

        try await RulingPerformer.revoke(
            rulingId: only.id, forScope: scope, store: store, world: declared)

        XCTAssertNil(declared.cached(forScopeKey: key, sourceHash: hash),
                     "a revoked rule must stop being checked immediately (spec \u{00a7}3.3)")
    }

    func test_editingInvalidatesTheDerivation() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "EditInvalidates")
        let declared = world(at: url)
        let scope = Statement.Scope.document(chapter.id)
        let key = DeclaredWorldStore.scopeKey(for: scope)
        try await RulingPerformer.rule(
            "Kelly never lys.", provenance: "ruled at the desk",
            forScope: scope, store: store, world: nil)
        let statement = try XCTUnwrap(store.statement(kind: .intent, scope: scope))
        let target = try XCTUnwrap(
            RulingsSection.parse(try renderedFile(of: statement, in: url)).rulings.first)
        let hash = DerivedWorld.sourceHash(of: "seeded")
        declared.store(seededDerivation(sourceHash: hash), forScopeKey: key)

        try await RulingPerformer.edit(
            rulingId: target.id, newText: "Kelly never lies.",
            forScope: scope, store: store, world: declared)

        XCTAssertNil(declared.cached(forScopeKey: key, sourceHash: hash))
    }

    /// A refusal leaves the reading alone. Invalidating on a write that never
    /// happened costs a spawn and a fistful of tokens for nothing.
    func test_aRefusedRulingLeavesTheDerivationStanding() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "RefusalKeepsDerivation")
        let declared = world(at: url)
        let scope = Statement.Scope.document(chapter.id)
        let key = DeclaredWorldStore.scopeKey(for: scope)
        let hash = DerivedWorld.sourceHash(of: "A ghost story.")
        declared.store(seededDerivation(sourceHash: hash), forScopeKey: key)

        try? await RulingPerformer.rule(
            "   ", provenance: "ruled at the desk", forScope: scope,
            store: store, world: declared)

        XCTAssertNotNil(
            declared.cached(forScopeKey: key, sourceHash: hash),
            "nothing was written, so nothing the reading was made from has moved")
    }

    /// The scope key is asked of `DeclaredWorldStore`, never spelled here — two
    /// spellings mean two caches and one of them is never hit (Task 2's rule).
    func test_theInvalidatedScopeIsThePiecesNotTheProjects() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "InvalidateScoped")
        let declared = world(at: url)
        let hash = DerivedWorld.sourceHash(of: "A ghost story.")
        let projectKey = DeclaredWorldStore.scopeKey(for: .project)
        declared.store(seededDerivation(sourceHash: hash), forScopeKey: projectKey)

        try await RulingPerformer.rule(
            "Kelly never lies.", provenance: "ruled at the desk",
            forScope: .document(chapter.id), store: store, world: declared)

        XCTAssertNotNil(
            declared.cached(forScopeKey: projectKey, sourceHash: hash),
            "a ruling on a chapter must not throw away the book's reading")
    }

    // MARK: - The membrane (spec §3.4)

    /// **Nothing derived can write itself.** Every verb here takes the writer's
    /// words as a `String`; none takes a `DerivedClause`, a `DerivedRule`, a
    /// `DerivedWorld` or a `BibleFact`. *Bless* and *correct* are `rule` with a
    /// provenance line — a `bless(_ fact: BibleFact…)` would be a route by which
    /// Claude's reading became the writer's declaration with no act in between,
    /// and the whole membrane is that there is no such route.
    ///
    /// A census over the source rather than a promise in a comment
    /// (`memory/feedback_census_over_warning.md`): the risk is an API that does
    /// not exist yet.
    func test_nothingDerivedCanWriteItself() throws {
        let source = try readSource("Maugham/Compiler/RulingPerformer.swift")
        let signatures = Self.functionSignatures(in: source)

        // Non-vacuity: a census that parsed nothing passes for any predicate.
        let names = Set(signatures.map(\.name))
        for verb in ["rule", "revoke", "edit", "restore"] {
            XCTAssertTrue(names.contains(verb),
                          "the census must actually see \u{201C}\(verb)\u{201D}; it found "
                          + "\(names.sorted().joined(separator: ", "))")
        }

        let offenders = Self.derivedWriters(in: signatures)
        XCTAssertTrue(
            offenders.isEmpty,
            "no verb may take a derived reading as its input \u{2014} the writer's words "
            + "are the only thing that enters their layer (spec \u{00a7}3.4). Found: "
            + "\(offenders.sorted().joined(separator: ", "))")
    }

    /// The control. Without it the census above passes for a predicate that
    /// matches nothing at all, and a real `bless(fact:)` would ship green.
    func test_theMembraneCensusWouldCatchABlessThatTakesADerivedFact() {
        let planted = """
            @MainActor enum RulingPerformer {
                static func rule(_ text: String, provenance: String,
                                 forScope scope: Statement.Scope,
                                 store: ProjectStore, world: DeclaredWorldStore?) async throws {}
                static func bless(_ fact: BibleFact, forScope scope: Statement.Scope,
                                  store: ProjectStore) async throws {}
                static func adopt(_ rule: DerivedRule, store: ProjectStore) async throws {}
            }
            """
        XCTAssertEqual(
            Self.derivedWriters(in: Self.functionSignatures(in: planted)),
            ["adopt", "bless"],
            "the predicate must catch both spellings of the offence \u{2014} and must NOT "
            + "catch `rule`, whose `DeclaredWorldStore` parameter is a cache to drop, "
            + "not a reading to write")
    }

    /// **Invalidation cannot be forgotten, because the compiler asks.** The
    /// cache parameter is explicit and undefaulted on every verb: a caller that
    /// has no store must write `nil` and mean it. A default would let a new call
    /// site skip it in silence, and the symptom — a writer checked against a
    /// rule they revoked — surfaces a run later with nothing red.
    func test_everyVerbTakesTheDerivationCacheExplicitly() throws {
        let source = try readSource("Maugham/Compiler/RulingPerformer.swift")
        for signature in Self.functionSignatures(in: source)
        where ["rule", "revoke", "edit", "restore"].contains(signature.name) {
            XCTAssertTrue(
                signature.parameters.contains("world: DeclaredWorldStore?"),
                "\(signature.name) must take the derivation cache: \(signature.parameters)")
            XCTAssertFalse(
                signature.parameters.contains("DeclaredWorldStore? ="),
                "\(signature.name)'s cache parameter must not be defaulted")
        }
    }

    // MARK: - Census machinery

    private struct FunctionSignature {
        let name: String
        let parameters: String
    }

    /// Every `func` in a source file paired with its parameter list, read by
    /// balancing parentheses rather than by a line-shaped regex — these
    /// signatures wrap.
    private static func functionSignatures(in source: String) -> [FunctionSignature] {
        var found: [FunctionSignature] = []
        var rest = Substring(source)
        while let funcRange = rest.range(of: "func ") {
            let afterKeyword = rest[funcRange.upperBound...]
            guard let open = afterKeyword.firstIndex(of: "(") else { break }
            let name = afterKeyword[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            var depth = 0
            var close: Substring.Index?
            var index = open
            while index < afterKeyword.endIndex {
                if afterKeyword[index] == "(" { depth += 1 }
                if afterKeyword[index] == ")" {
                    depth -= 1
                    if depth == 0 { close = index; break }
                }
                index = afterKeyword.index(after: index)
            }
            guard let close else { break }
            found.append(FunctionSignature(
                name: name,
                parameters: String(afterKeyword[afterKeyword.index(after: open)..<close])))
            rest = afterKeyword[afterKeyword.index(after: close)...]
        }
        return found
    }

    /// The names of functions whose parameters name one of Claude's readings.
    ///
    /// Compared as whole identifier TOKENS, so `DeclaredWorldStore` can never be
    /// mistaken for `DerivedWorld` by a substring match — the trap that would
    /// make this census fire on the one parameter it is meant to allow.
    private static func derivedWriters(in signatures: [FunctionSignature]) -> [String] {
        let readings: Set<String> = [
            "DerivedClause", "DerivedRule", "DerivedWorld", "BibleFact", "Diagnostic"
        ]
        return signatures
            .filter { signature in
                !Set(signature.parameters.components(
                    separatedBy: CharacterSet.alphanumerics.inverted))
                    .intersection(readings).isEmpty
            }
            .map(\.name)
            .sorted()
    }

    private func readSource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath),
                          encoding: .utf8)
    }
}

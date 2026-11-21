import XCTest
import MaughamCore
@testable import Maugham

/// **Shell p4 Task 6 fix round — an edition's verbs.** Every row→verb
/// wiring is called directly (`ResolveEditionActs`, the head's statics) with
/// recording closures, or against a real project with the production actions;
/// nothing is pressed (tripwire 33). The stale-round sequences the review
/// found (C1) are driven over ONE held copy of a round, as the list and the
/// centre's report each hold one.
@MainActor
final class ResolveEditionVerbTests: XCTestCase {

    // MARK: - Harness

    private struct Harness {
        let projectURL: URL
        let store: ProjectStore
        let documentStore: DocumentStore
        let doc: Document
        var rounds: TranslationRoundStore { TranslationRoundStore(projectURL: projectURL) }
    }

    /// One three-paragraph chapter, open (the `¶id`s a directive anchors
    /// to), and a publish config — `TranslationRoundActionsTests`' project.
    private func makeHarness() async throws -> Harness {
        let root = TestTemp.root.appendingPathComponent("EditionVerbs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let path = "manuscript/c1.md"
        try "The fog came in.\n\nShe closed the door.\n\nNobody spoke."
            .write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "Env", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-1", title: "Chapter 1", type: .document, path: path)],
            research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        store.documentStore = documentStore
        let doc = try await Document.load(url: root.appendingPathComponent(path),
                                          device: "test", session: "s", presenter: nil)
        documentStore.register(document: doc, for: path)
        try await PublishConfigStore(projectURL: root).save(
            PublishConfig(metadata: .init(title: "Env", author: "A", language: "en")))
        return Harness(projectURL: root, store: store, documentStore: documentStore, doc: doc)
    }

    private func actions(_ h: Harness) -> TranslationRoundActions {
        TranslationRoundActions.production(store: h.store, documentStore: h.documentStore,
                                           projectURL: h.projectURL, world: nil)
    }

    private func departure(_ id: String, pid: String) -> TranslationRound.DepartureRecord {
        .init(id: id, paragraphId: pid, verdict: "drifted", kind: "tone", note: "softer", gloss: "it whispers")
    }

    /// A finished round on the harness's chapter, appended to its ledger.
    private func seed(_ h: Harness, departures: [String] = [],
                      glossary: [(String, String)] = []) throws -> TranslationRound {
        var round = TranslationRound(number: 1, language: "es", docId: h.doc.docId, startedAt: Date())
        round.endedAt = Date()
        round.departures = departures.enumerated().map { departure($1, pid: h.doc.sequence[$0 % 3]) }
        round.glossaryProposals = glossary.map {
            .init(term: $0.0, rendering: $0.1, reason: "r", adopted: false)
        }
        try h.rounds.append(round)
        return round
    }

    private func stored(_ h: Harness) throws -> TranslationRound {
        try XCTUnwrap(h.rounds.record(language: "es", docId: h.doc.docId, number: 1))
    }

    private func briefRulings(_ h: Harness) throws -> [Ruling] {
        guard let statement = h.store.statement(kind: .editionBrief("es"), scope: .project) else { return [] }
        return RulingsSection.parse(try h.store.statementText(of: statement)).rulings
    }

    // MARK: - C1: a stale copy undoes nothing

    /// **Two Fines on one chapter, back to back, from the same held round.**
    /// Before the fix the second wrote the held copy whole and A came back.
    func test_twoVerbsOnOneChapterBackToBackKeepBoth() async throws {
        let h = try await makeHarness()
        let held = try seed(h, departures: ["a", "b"])
        let verbs = actions(h)
        guard case .done = await verbs.dismiss(held, "a"), case .done = await verbs.dismiss(held, "b") else {
            return XCTFail("Fine was refused")
        }
        XCTAssertEqual(try stored(h).departures.map(\.dismissed), [true, true],
                       "the second Fine undid the first")
        XCTAssertEqual(EditionStatusRows.changesToLookAt(try stored(h)), 0)
        await h.documentStore.close()
    }

    /// **Adopt then Skip from one held round**: no lost adoption, and a
    /// second Adopt files no second glossary ruling.
    func test_adoptThenSkipKeepsTheAdoptionAndFilesOneRuling() async throws {
        let h = try await makeHarness()
        let held = try seed(h, glossary: [("fog", "niebla"), ("moor", "páramo")])
        let verbs = actions(h)
        let fog = held.glossaryProposals[0].identity, moor = held.glossaryProposals[1].identity
        guard case .filed = await verbs.adopt(held, fog) else { return XCTFail("Adopt was refused") }
        guard case .done = await verbs.skip(held, moor) else { return XCTFail("Skip was refused") }
        let after = try stored(h)
        XCTAssertTrue(after.glossaryProposals[0].adopted, "Skip's stale copy erased the adoption")
        XCTAssertEqual(after.glossaryProposals[1].skipped, true)
        guard case .refused(let sentence) = await verbs.adopt(held, fog) else {
            return XCTFail("a second Adopt over a stale copy was taken")
        }
        XCTAssertEqual(sentence, TranslationRoundReport.alreadyAnsweredLine)
        guard case .refused = await verbs.skip(held, fog) else {
            return XCTFail("Skip over an adopted proposal was taken")
        }
        XCTAssertEqual(try briefRulings(h).count, 1, "exactly one glossary ruling")
        await h.documentStore.close()
    }

    /// **The list and the open report acting on the same round**: each holds
    /// its own copy; both decisions stand, the report re-reads what the list
    /// wrote (`PublishCentreModel.rereadRound`, on the announced write), and
    /// each write is announced.
    func test_theListAndTheOpenReportActingOnOneRoundKeepBoth() async throws {
        let h = try await makeHarness()
        let held = try seed(h, departures: ["a", "b"])
        let centre = PublishCentreModel()
        centre.show(round: held)
        var heard = 0
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: capture-only recorder of the scoped post a round write makes
            forName: .maughamTranslationRoundChanged, object: nil, queue: nil) { _ in heard += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        // The list's Fine on A, through its act over its own read.
        var verbs = ResolveEditionVerbs()
        verbs.round = actions(h)
        let read = ResolveEditionItems.Read(language: "es", rounds: [h.doc.docId: held])
        let a = ResolveItem.translationChange(docId: h.doc.docId, language: "es", round: 1, held.departures[0])
        _ = await ResolveEditionActs.fine(a, read: read, verbs: verbs)
        // The report's Fine on B, over the copy it opened with.
        _ = await actions(h).dismiss(try XCTUnwrap(centre.selectedRound), "b")

        XCTAssertEqual(try stored(h).departures.map(\.dismissed), [true, true])
        XCTAssertEqual(heard, 2, "every record write is announced (tripwire 21's helper)")
        centre.rereadRound { h.rounds.record(language: $0, docId: $1, number: $2) }
        XCTAssertEqual(centre.selectedRound?.departures.map(\.dismissed), [true, true],
                       "the report re-reads the round the list wrote")
        await h.documentStore.close()
    }

    // MARK: - I2: filing settles

    /// **Keep mine and Make it a rule settle the change as Fine does**
    /// (controller's ruling): it leaves the list, Status's count and the
    /// mark; the report keeps it with "Ruled."; a second filing — from any
    /// held copy — files nothing.
    func test_filingSettlesTheChangeAndASecondFilingFilesNothing() async throws {
        let h = try await makeHarness()
        let held = try seed(h, departures: ["a", "b"])
        let verbs = actions(h)
        guard case .filed(let written?, _, _) = await verbs.keepMine(
            held, held.departures[0].paragraphId, "keep it", .edition("es"), "a") else {
            return XCTFail("Keep mine did not answer with the settled round")
        }
        XCTAssertFalse(EditionStatusRows.isToLookAt(written.departures[0]))
        XCTAssertEqual(written.departures[0].ruled, true)
        guard case .filed(_?, _, _) = await verbs.makeRule(held, "Never soften an oath.", "b") else {
            return XCTFail("Make it a rule did not settle")
        }
        let after = try stored(h)
        XCTAssertEqual(EditionStatusRows.changesToLookAt(after), 0)
        XCTAssertEqual(ResolveEditionItems.items(language: "es", isSource: false, docIds: [h.doc.docId],
                                                 read: .init(language: "es", rounds: [h.doc.docId: after])), [])
        XCTAssertFalse(ResolveEditionItems.leavesSomething(after), "the mark clears")
        XCTAssertEqual(TranslationRoundReport.departureRows(after, sources: [:])
                        .map(\.outcomeLine), [TranslationRoundReport.ruledOutcomeLine,
                                              TranslationRoundReport.ruledOutcomeLine],
                       "the report keeps the change, saying what the author did")
        XCTAssertEqual(try briefRulings(h).count, 2)

        for second in [await verbs.keepMine(held, held.departures[0].paragraphId, "again", .edition("es"), "a"),
                       await verbs.makeRule(held, "Again.", "a")] {
            guard case .refused(let sentence) = second else { return XCTFail("a settled change filed again") }
            XCTAssertEqual(sentence, TranslationRoundReport.alreadySettledLine)
        }
        XCTAssertEqual(try briefRulings(h).count, 2, "nothing filed twice")
        await h.documentStore.close()
    }

    // MARK: - I1: the mark ⇔ the list

    /// **An edition row is marked exactly while its list holds something**,
    /// from one read, kind by kind — and a verb that settles the last change
    /// clears the mark's disk half.
    func test_anEditionIsMarkedExactlyWhenItsListHoldsSomething() async throws {
        func question(_ language: String) -> ResolveItem {
            .note(ProjectAnnotation(docId: "doc-a", annotation: Annotation(
                id: "q", kind: .query, paragraphId: "aa11", body: "?", suggestedText: nil, priorText: nil,
                createdAt: Date(), createdBySession: nil, status: .open, userResponse: nil,
                resolvedAt: nil, isStale: false, author: nil, language: language, reviewPassId: nil,
                compilerRunId: nil, compilerRound: nil)))
        }
        var change = TranslationRound(number: 1, language: "es", docId: "doc-a", startedAt: Date())
        change.departures = [departure("d", pid: "aa11")]
        var glossary = TranslationRound(number: 1, language: "es", docId: "doc-a", startedAt: Date())
        glossary.glossaryProposals = [.init(term: "fog", rendering: "niebla", reason: "", adopted: false)]
        let pending = DesignProposalStore.Proposal(
            id: "p", designerName: "T", round: 1, language: nil, created: Date(), status: .pending,
            specMarkdown: "", filePaths: [], sampleResult: nil, revertNote: nil)
        let stop = TectonicLogParser.Diagnostic(level: .error, file: nil, line: nil, message: "x",
                                                contextLines: [], pieceID: "doc-a", paragraphID: nil)
        struct Case { let name: String; let questions: [ResolveItem]; let read: ResolveEditionItems.Read }
        let cases = [
            Case(name: "none", questions: [], read: .init(language: "es")),
            Case(name: "questions only", questions: [question("es")], read: .init(language: "es")),
            Case(name: "another language's question", questions: [question("fr")], read: .init(language: "es")),
            Case(name: "changes only", questions: [], read: .init(language: "es", rounds: ["doc-a": change])),
            Case(name: "glossary only", questions: [], read: .init(language: "es", rounds: ["doc-a": glossary])),
            Case(name: "a design proposal", questions: [], read: .init(language: "es", proposals: [pending])),
            Case(name: "a stopping problem", questions: [], read: .init(language: "es", problems: [stop])),
        ]
        for c in cases {
            let snapshot = ResolveSnapshot(items: c.questions, sequences: [:], paragraphText: [:], unreadableDocIds: [])
            let listed = !ResolveReader.snapshot(
                scope: .edition(language: "es", isSource: false, docIds: ["doc-a"]),
                annotations: ProjectAnnotationsSnapshot(
                    annotations: c.questions.compactMap { if case .note(let n) = $0 { return n } else { return nil } },
                    unreadableDocIds: [], sequences: [:]),
                tasks: [], findings: [:], paragraphText: [:], figureOwners: [:]).items.isEmpty
                || !ResolveEditionItems.items(language: "es", isSource: false, docIds: ["doc-a"], read: c.read).isEmpty
            let marked = ResolveEditionItems.markedEditions(
                editions: [("es", false)],
                questionLanguages: ResolveEditionItems.questionLanguages(snapshot),
                roundsLeaveSomething: c.read.rounds.values.contains(where: ResolveEditionItems.leavesSomething)
                    ? ["es"] : [],
                bookLevel: c.read.pendingProposal != nil || !c.read.problems.isEmpty).contains("es")
            XCTAssertEqual(marked, listed, c.name)
        }

        // A verb clears it: Fine on the last change, then the mark's disk read.
        let h = try await makeHarness()
        let held = try seed(h, departures: ["a"])
        XCTAssertEqual(ResolveEditionItems.languagesLeavingSomething(
            projectURL: h.projectURL, languages: ["es"], docIds: [h.doc.docId]), ["es"], "premise")
        _ = await actions(h).dismiss(held, "a")
        XCTAssertEqual(ResolveEditionItems.languagesLeavingSomething(
            projectURL: h.projectURL, languages: ["es"], docIds: [h.doc.docId]), [])
        await h.documentStore.close()
    }

    /// Every record write posts the round-changed event, and everything that
    /// shows a round's record listens: the list, the tree's mark, Status and
    /// the centre's report.
    func test_aRoundRecordWriteIsAnnouncedAndHeard() throws {
        let actionsCode = SourceScan.codeLines(of: try SourceTree.read(
            "Maugham/Views/Publish/TranslationRoundActions.swift")).joined(separator: "\n")
        XCTAssertTrue(actionsCode.contains("MaughamEvent.postTranslationRoundChanged(projectURL: projectURL)"))
        XCTAssertFalse(actionsCode.contains(".update("), "no whole-value write of a held round")
        for (type, file) in [("ResolvePane", "pane"), ("ResolvePresenceWatch", "mark"),
                             ("EditionStatusHost", "Status"), ("PublishPreviewModifier", "report")] {
            let code = try SourceTree.sourceOfType(type, under: ["Maugham"])
            XCTAssertTrue(code.contains(".onProjectEvent(.maughamTranslationRoundChanged"),
                          "the \(file) does not hear a round's record change")
        }
    }

    // MARK: - I3: Discard decides over the store

    func test_discardOverAStaleCopyOfAnApprovedProposalIsRefused() throws {
        let url = TestTemp.root.appendingPathComponent("discard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = DesignProposalStore(projectURL: url)
        let staleCopy = try store.stage(report: DesignerReport(specMarkdown: "A page.", files: [
            .init(path: "template.tex", content: "% tex")]), round: 1, designerName: "T", language: nil)
        try store.updateStatus(id: staleCopy.id, .approved)
        XCTAssertEqual(staleCopy.status, .pending, "premise: the list still holds it as waiting")
        guard case .refused(let sentence) = DesignGatePromotion.discard(staleCopy, projectURL: url) else {
            return XCTFail("an approved proposal was discarded through a stale copy")
        }
        XCTAssertEqual(sentence, DesignGate.notPendingRefusal)
        XCTAssertEqual(try store.load(id: staleCopy.id).status, .approved, "the store is unchanged")
        XCTAssertNil(try store.load(id: staleCopy.id).revertNote)
    }

    // MARK: - Row → verb wiring

    private struct Recorded {
        var calls: [String] = []
    }

    /// Every list verb reaches the one verb, with the round from the CURRENT
    /// read (not a copy the row drew), the departure's id and paragraph, and
    /// the proposal's identity.
    func test_everyRowVerbReachesItsVerbWithTheRightIdentity() async throws {
        var calls: [String] = []
        var verbs = ResolveEditionVerbs()
        verbs.round.dismiss = { round, id in calls.append("fine \(round.number) \(id)"); return .done(nil, "") }
        verbs.round.keepMine = { round, pid, words, _, settling in
            calls.append("keep \(round.number) \(pid) \(words) \(settling ?? "-")"); return .done(nil, "")
        }
        verbs.round.makeRule = { round, text, settling in
            calls.append("rule \(round.number) \(text) \(settling ?? "-")"); return .done(nil, "")
        }
        verbs.round.adopt = { round, identity in calls.append("adopt \(round.number) \(identity)"); return .done(nil, "") }
        verbs.round.skip = { round, identity in calls.append("skip \(round.number) \(identity)"); return .done(nil, "") }
        verbs.approve = { calls.append("approve \($0.id)"); return .refused("") }
        verbs.discard = { calls.append("discard \($0.id)"); return .refused("") }

        // The row drew round 3; the read now holds round 4 — the verb uses 4.
        var current = TranslationRound(number: 4, language: "es", docId: "doc-a", startedAt: Date())
        current.glossaryProposals = [.init(term: "moor", rendering: "páramo", reason: "", adopted: false),
                                     .init(term: "fog", rendering: "niebla", reason: "", adopted: false)]
        let read = ResolveEditionItems.Read(language: "es", rounds: ["doc-a": current])
        let change = ResolveItem.translationChange(docId: "doc-a", language: "es", round: 3,
                                                   departure("d7", pid: "pp11"))
        let fog = ResolveItem.glossaryProposal(docId: "doc-a", language: "es", round: 3,
                                               .init(term: "fog", rendering: "niebla", reason: "", adopted: false))
        _ = await ResolveEditionActs.fine(change, read: read, verbs: verbs)
        _ = await ResolveEditionActs.keepMine(change, instruction: "mine", home: .edition("es"), read: read, verbs: verbs)
        _ = await ResolveEditionActs.makeRule(change, text: "rule", read: read, verbs: verbs)
        _ = await ResolveEditionActs.adopt(fog, read: read, verbs: verbs)
        _ = await ResolveEditionActs.skip(fog, read: read, verbs: verbs)
        let proposal = DesignProposalStore.Proposal(
            id: "prop-9", designerName: "T", round: 1, language: nil, created: Date(), status: .pending,
            specMarkdown: "", filePaths: [], sampleResult: nil, revertNote: nil)
        _ = await ResolveEditionActs.decide(.approve, proposal, verbs: verbs)
        _ = await ResolveEditionActs.decide(.discard, proposal, verbs: verbs)
        XCTAssertEqual(calls, ["fine 4 d7", "keep 4 pp11 mine d7", "rule 4 rule d7",
                               "adopt 4 \u{AB}fog\u{BB}\u{2192}\u{AB}niebla\u{BB}", "skip 4 \u{AB}fog\u{BB}\u{2192}\u{AB}niebla\u{BB}",
                               "approve prop-9", "discard prop-9"])
        // A row whose piece the read no longer holds reaches nothing.
        let gone = await ResolveEditionActs.fine(change, read: .init(language: "es"), verbs: verbs)
        XCTAssertNil(gone)
    }

    /// **A glossary list that changed between draw and press** adopts the
    /// term the writer pressed: the production verb resolves the identity
    /// against the stored round, whatever position it now holds.
    func test_aGlossaryProposalIsFiledByIdentityNotPosition() async throws {
        let h = try await makeHarness()
        var round = TranslationRound(number: 1, language: "es", docId: h.doc.docId, startedAt: Date())
        round.endedAt = Date()
        round.glossaryProposals = [.init(term: "moor", rendering: "páramo", reason: "", adopted: false),
                                   .init(term: "fog", rendering: "niebla", reason: "", adopted: false)]
        try h.rounds.append(round)
        // Drawn as if "fog" were first.
        var drawn = round
        drawn.glossaryProposals.reverse()
        _ = await actions(h).adopt(drawn, drawn.glossaryProposals[0].identity)
        let after = try stored(h)
        XCTAssertEqual(after.glossaryProposals.map(\.adopted), [false, true], "the pressed term, not its old position")
        XCTAssertEqual(try briefRulings(h).first?.glossary?.term, "fog")
        await h.documentStore.close()
    }

    /// The rows' buttons call those acts and nothing else.
    func test_theRowsButtonsCallTheActs() throws {
        let code = SourceScan.codeLines(of: try SourceTree.read(
            "Maugham/Views/Resolve/ResolveEditionItems.swift")).joined(separator: "\n")
        for token in ["onFine: { run { await ResolveEditionActs.fine(item, read: read, verbs: verbs) } }",
                      "await ResolveEditionActs.keepMine(item, instruction: instruction, home: home,",
                      "run { await ResolveEditionActs.makeRule(item, text: text, read: read, verbs: verbs) }",
                      "run { await ResolveEditionActs.adopt(item, read: read, verbs: verbs) }",
                      "run { await ResolveEditionActs.skip(item, read: read, verbs: verbs) }",
                      "await ResolveEditionActs.decide(verb, proposal, verbs: verbs)",
                      "Button(DepartmentRunState.runBookTitle) { runBook() }",
                      "Self.runBook(language: language, book: book, session: session, verbs: verbs)",
                      "Button(DepartmentRunState.cancelTitle) { verbs.cancelRound() }",
                      "let outcome = Self.runDesign(direction, verbs: verbs)",
                      "let outcome = Self.requestChanges(direction, verbs: verbs)",
                      "Button(DepartmentRunState.cancelTitle) { verbs.cancelDesign() }",
                      // The production closures.
                      "await DepartmentPaneHost.startBookRun(",
                      "pipeline.runBook(documentIds: documentIds, language: language)",
                      "roster.pipeline.cancel()", "roster.translator.cancel()",
                      "designer.runDesign(direction: direction, language: nil)",
                      "requestChanges: { words in DepartmentDesignRow.sendChanges(words, to: designer) }",
                      "cancelDesign: { designer.cancel() }"] {
            XCTAssertTrue(code.contains(token), token)
        }
    }

    // MARK: - The head's verbs, called directly

    func test_runWholeBookRunsExactlyTheSetItCountsAndRefusesInWords() async throws {
        var started: [(String, [String])] = []
        var verbs = EditionHeadVerbs()
        verbs.startBookRun = { started.append(($0, $1)); return .init() }
        let busy = await EditionHeadView.runBook(language: "es", book: ["a"], session: .busy(language: "fr"),
                                                 verbs: verbs)
        XCTAssertEqual(busy.notice, DepartmentRunState.busyReason(language: "fr"))
        let empty = await EditionHeadView.runBook(language: "es", book: [], session: .free, verbs: verbs)
        XCTAssertEqual(empty.notice, DepartmentRunState.nothingInTheBook)
        let bad = await EditionHeadView.runBook(language: "not a tag!", book: ["a"], session: .free, verbs: verbs)
        XCTAssertEqual(bad.notice, DepartmentRunState.unusableTag(language: "not a tag!"))
        XCTAssertTrue(started.isEmpty, "a refusal starts nothing")
        _ = await EditionHeadView.runBook(language: "es", book: ["a", "c"], session: .free, verbs: verbs)
        XCTAssertEqual(started.map(\.0), ["es"])
        XCTAssertEqual(started.map(\.1), [["a", "c"]], "the run is over exactly the set it counted")
    }

    /// The cast sheet's Confirm names the translator, then runs the queue
    /// it was asked over.
    func test_theCastSheetsConfirmRunsTheQueueItWasAskedOver() async throws {
        let h = try await makeHarness()
        var ran: [(String, [String])] = []
        var verbs = EditionHeadVerbs()
        verbs.runBookNamed = { ran.append(($0, $1)) }
        let prompt = DepartmentCastPrompt(ask: .nameForBookRun(language: "xx", documentIds: ["doc-1"]))
        let notice = await EditionHeadView.confirmCast(
            DepartmentCastAnswer(language: nil, name: "Ana", reader: nil, collator: nil),
            prompt: prompt, store: h.store, verbs: verbs)
        XCTAssertNil(notice)
        XCTAssertEqual(ran.map(\.0), ["xx"])
        XCTAssertEqual(ran.map(\.1), [["doc-1"]])
        XCTAssertEqual(EditionStatus.translatorName(for: "xx", in: h.store.manifest), "Ana")
        await h.documentStore.close()
    }

    func test_runDesignAndRequestChangesSpendTheWordsOnlyWhenTheyWent() {
        var asked: [String?] = []
        var verbs = EditionHeadVerbs()
        verbs.runDesign = { asked.append($0); return nil }
        verbs.requestChanges = { asked.append($0); return "Not now." }
        XCTAssertEqual(EditionHeadView.runDesign("  ", verbs: verbs).spent, true)
        XCTAssertEqual(EditionHeadView.runDesign(" Quieter. ", verbs: verbs).spent, true)
        let refused = EditionHeadView.requestChanges("More air.", verbs: verbs)
        XCTAssertEqual(refused.notice, "Not now.")
        XCTAssertFalse(refused.spent, "refused words stay in the field")
        XCTAssertEqual(asked, [nil, "Quieter.", "More air."])
        // An unwired head (a probe) refuses in words.
        XCTAssertEqual(EditionHeadView.runDesign("x", verbs: EditionHeadVerbs()).notice,
                       DepartmentDesignRow.noDesignerWired)
    }

    // MARK: - The posture gates as wired

    /// A Mac that may not answer or rule — here the undecided posture, which
    /// offers only annotating — is offered no change, glossary or design
    /// verb; the author every one.
    func test_eachVerbIsHiddenWhereThePostureRefusesIt() {
        let refused = TranslationAuthorVerbs.decide(document: .settling, editionBrief: .settling,
                                                    pieceIntent: .settling)
        XCTAssertEqual(DepartureRowView.offers(isSettled: false, verbs: refused), [])
        XCTAssertFalse(TranslationRoundReport.glossaryOffers(refused).adopt)
        XCTAssertFalse(TranslationRoundReport.glossaryOffers(refused).skip)
        XCTAssertFalse(ResolvePane.mayDecideDesign(.settling))
        XCTAssertEqual(EditionDesignRow.verbs(status: .pending, mayDecide: ResolvePane.mayDecideDesign(.settling)), [])
        XCTAssertFalse(EditionHeadView.offersRun(docIds: ["a"], mayTranslate: { _ in Posture.settling.allows(.translate) }))

        let author = TranslationAuthorVerbs.decide(document: .author, editionBrief: .author, pieceIntent: .author)
        XCTAssertEqual(DepartureRowView.offers(isSettled: false, verbs: author), [.fine, .keepMine, .makeRule])
        XCTAssertTrue(TranslationRoundReport.glossaryOffers(author).adopt)
        XCTAssertTrue(ResolvePane.mayDecideDesign(.author))
        XCTAssertTrue(EditionHeadView.offersRun(docIds: ["a"], mayTranslate: { _ in Posture.author.allows(.translate) }))

        // Wired: the pane asks the Visual Language statement's posture; the
        // head's design controls stand behind it.
        let pane = SourceScan.codeLines(of: try! SourceTree.read("Maugham/Views/Resolve/ResolvePane.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(pane.contains("mayDecideDesign: Self.mayDecideDesign(postureOfStatement(.visualLanguage)),"))
        let head = SourceScan.codeLines(of: try! SourceTree.sourceOfType("EditionHeadView", under: ["Maugham"]))
            .joined(separator: "\n")
        XCTAssertTrue(head.contains("if mayDecideDesign {"))
    }

    // MARK: - The one question predicate, the splice, the click

    /// The live splice keeps an open piece's notes in the edition's
    /// language only — through `isQuestion`, the reader's own predicate.
    func test_theLiveSpliceListsTheEditionsQuestionsOnly() {
        func note(_ id: String, _ language: String?) -> Annotation {
            Annotation(id: id, kind: .query, paragraphId: "aa11", body: id, suggestedText: nil, priorText: nil,
                       createdAt: Date(), createdBySession: nil, status: .open, userResponse: nil,
                       resolvedAt: nil, isStale: false, author: nil, language: language, reviewPassId: nil,
                       compilerRunId: nil, compilerRound: nil)
        }
        let live = ["doc-a": ResolveLivePiece(notes: [note("es", "ES"), note("fr", "fr"), note("plain", nil)],
                                              todos: [], sequence: ["aa11"], paragraphs: [:])]
        let spliced = ResolvePane.splicing(.empty, scope: .edition(language: "es", isSource: false, docIds: ["doc-a"]),
                                           live: live)
        XCTAssertEqual(spliced.items.map(\.id), ["note:doc-a/es"])
        XCTAssertEqual(ResolvePane.splicing(.empty, scope: .edition(language: "en", isSource: true, docIds: ["doc-a"]),
                                            live: live).items, [], "the Source has no questions")
        XCTAssertTrue(ResolveEditionItems.isQuestion(note("x", "Es"), in: "eS"))
        XCTAssertNil(ResolveEditionItems.questionLanguage(of: note("x", nil)))

        // The click: a question opens its paragraph in the edition's language.
        let q = ProjectAnnotation(docId: "doc-a", annotation: note("es", "es"))
        XCTAssertEqual(ResolvePane.editionQuestionReveal(q, language: "es"),
                       TranslationReveal(docId: "doc-a", language: "es", paragraphId: "aa11"))
        XCTAssertNil(ResolvePane.editionQuestionReveal(ProjectAnnotation(docId: "doc-a", annotation: note("fr", "fr")),
                                                       language: "es"))
    }

    /// An edition reads its questions from the presence read: no walk is
    /// asked of the store (review I4).
    func test_anEditionReadsItsQuestionsFromThePresenceReadWithoutAWalk() async throws {
        let h = try await makeHarness()
        let scope = ResolveScope.edition(language: "es", isSource: false, docIds: ["doc-1"])
        let question = ProjectAnnotation(docId: "doc-9", annotation: Annotation(
            id: "q", kind: .query, paragraphId: "aa11", body: "?", suggestedText: nil, priorText: nil,
            createdAt: Date(), createdBySession: nil, status: .open, userResponse: nil, resolvedAt: nil,
            isStale: false, author: nil, language: "es", reviewPassId: nil, compilerRunId: nil, compilerRound: nil))
        var presence = ResolvePresence.BookReading()
        presence.languageNotes = [question]
        var walks = ResolveWalkHold()
        let key = ResolvePane.readKey(scope: .edition(language: "es", isSource: false, docIds: ["doc-1", "doc-9"]),
                                      annotationsToken: 0, store: h.store, documentStore: h.documentStore,
                                      diagnostics: nil, localName: "", presence: presence)
        let read = ResolvePane.refreshed(.empty, step: .read, key: key, walks: &walks, presence: presence,
                                         store: h.store, documentStore: h.documentStore, diagnostics: nil)
        XCTAssertEqual(read.items.map(\.id), ["note:doc-9/q"])
        XCTAssertNil(walks.annotations, "an edition with a presence read asks no annotation walk")
        XCTAssertNil(walks.tasks)
        _ = scope
        await h.documentStore.close()
    }

    // MARK: - Compile problems, the imprint

    /// Only what stopped a book is listed and marks: a refused or failed
    /// compile's errors; a compile that landed with warnings, nothing.
    func test_onlyProblemsThatStoppedABookAreListed() {
        let error = TectonicLogParser.Diagnostic(level: .error, file: nil, line: nil, message: "e",
                                                 contextLines: [], pieceID: "a")
        let warning = TectonicLogParser.Diagnostic(level: .warning, file: nil, line: nil, message: "w",
                                                   contextLines: [], pieceID: "a")
        var failed = DepartmentCompileState()
        failed.phase = .failed("x")
        failed.problems = [error, warning]
        XCTAssertEqual(ResolveEditionItems.stoppingProblems(failed), [error])
        var refused = DepartmentCompileState()
        refused.phase = .refused("x")
        refused.problems = [error]
        XCTAssertEqual(ResolveEditionItems.stoppingProblems(refused), [error])
        var landed = DepartmentCompileState()
        landed.phase = .idle
        landed.problems = [warning]
        XCTAssertEqual(ResolveEditionItems.stoppingProblems(landed), [], "warnings stay behind Show Problems")
        let window = try! SourceTree.windowSource()
        XCTAssertTrue(window.contains("ResolveEditionItems.stoppingProblems(publishCentre.compileRunner.state)"),
                      "the mark asks the list's predicate")
    }

    /// Run Whole Book runs the imprint the window stands on (the compile
    /// bar's one choice), said in its line; a name the config no longer
    /// declares is the whole book.
    func test_runWholeBookRunsTheChosenImprintAndSaysSo() throws {
        var config = PublishConfig(metadata: .init(title: "T", author: "A", language: "en"))
        var imprint = PublishConfig.Imprint()
        imprint.sections = ["b": PublishConfig.Section()]
        config.imprints = ["Volume One": imprint]
        let scoped = ResolveEditionItems.runScope(docIds: ["a", "b", "c"], persisted: "Volume One", config: config)
        XCTAssertEqual(scoped.docIds, ["b"])
        XCTAssertEqual(scoped.imprint, "Volume One")
        let gone = ResolveEditionItems.runScope(docIds: ["a", "b"], persisted: "Gone", config: config)
        XCTAssertEqual(gone.docIds, ["a", "b"])
        XCTAssertNil(gone.imprint)
        XCTAssertEqual(ResolveEditionItems.runScopeLine(count: 1, imprint: "Volume One"),
                       "Runs the 1 chapter of \u{201C}Volume One\u{201D}, the imprint chosen above the book.")
        XCTAssertEqual(ResolveEditionItems.runScopeLine(count: 3, imprint: nil),
                       "Runs every chapter of the book: 3 chapters.")
    }
}

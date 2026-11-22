import XCTest
import SwiftUI
import AppKit
import MaughamCore
@testable import Maugham

/// **Shell p4 Task 6 — an edition's To resolve.** The edition is a scope of
/// its own: its language's questions (the walks'), the changes and glossary
/// proposals its pieces' latest finished rounds left, a pending design
/// proposal and the last compile's problems (`ResolveEditionItems`). Pure
/// tests over values; the mounted ones build the column the way production
/// does (`RightColumnFixture`) and press nothing (tripwire 33).
@MainActor
final class ResolveEditionTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private let t = Date(timeIntervalSince1970: 1_700_000_000)
    private let es = ResolveScope.edition(language: "es", isSource: false, docIds: ["doc-a", "doc-b"])
    private let source = ResolveScope.edition(language: "en", isSource: true, docIds: ["doc-a", "doc-b"])

    // MARK: - Builders

    private func note(_ id: String, on docId: String, language: String?,
                      status: AnnotationStatus = .open) -> ProjectAnnotation {
        ProjectAnnotation(docId: docId, annotation: Annotation(
            id: id, kind: .query, paragraphId: "aa11", body: id, suggestedText: nil, priorText: nil,
            createdAt: t, createdBySession: nil, status: status, userResponse: nil, resolvedAt: nil,
            isStale: false, author: nil, language: language, reviewPassId: nil,
            compilerRunId: nil, compilerRound: nil))
    }

    private func departure(_ id: String, pid: String = "aa11",
                           outcome: TranslationRound.DepartureOutcome? = nil,
                           dismissed: Bool? = nil) -> TranslationRound.DepartureRecord {
        TranslationRound.DepartureRecord(id: id, paragraphId: pid, verdict: "drifted", kind: "tone",
                                         note: "softer than yours", gloss: "it now says she whispers",
                                         outcome: outcome, dismissed: dismissed)
    }

    private func round(_ number: Int, on docId: String, departures: [TranslationRound.DepartureRecord] = [],
                       glossary: [TranslationRound.GlossaryProposalRecord] = [],
                       summary: String? = nil) -> TranslationRound {
        var round = TranslationRound(number: number, language: "es", docId: docId,
                                     startedAt: t.addingTimeInterval(Double(number) * 60))
        round.endedAt = t.addingTimeInterval(Double(number) * 60 + 30)
        round.departures = departures
        round.glossaryProposals = glossary
        round.summary = summary
        return round
    }

    private func proposal(_ status: DesignProposalStore.Status, round: Int = 1) -> DesignProposalStore.Proposal {
        DesignProposalStore.Proposal(
            id: "prop-\(round)", designerName: "Tschichold", round: round, language: nil,
            created: t, status: status, specMarkdown: "A quiet page.", filePaths: ["template.tex"],
            sampleResult: nil, revertNote: nil)
    }

    private func problem(_ message: String, on piece: String = "doc-a") -> TectonicLogParser.Diagnostic {
        TectonicLogParser.Diagnostic(level: .error, file: nil, line: nil, message: message,
                                     contextLines: [], pieceID: piece, paragraphID: "aa11")
    }

    private func ids(_ items: [ResolveItem]) -> [String] { items.map(\.id) }

    private func projectURL() throws -> URL {
        let url = TestTemp.root.appendingPathComponent("edition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The questions

    /// An edition's list holds its OWN language's open questions on the
    /// book's pieces — not another language's, not an unlanguaged note, not a
    /// settled one, not one on a piece the book does not hold.
    ///
    /// Disable experiment: drop the `language ==` filter in the edition read
    /// (`ResolveReader.snapshot`'s `.edition` arm) and this goes red.
    func test_anEditionsListHoldsItsLanguagesQuestionsOnly() {
        let walk = ProjectAnnotationsSnapshot(
            annotations: [note("q-es", on: "doc-a", language: "es"),
                          note("q-ES", on: "doc-b", language: "ES"),
                          note("q-fr", on: "doc-a", language: "fr"),
                          note("plain", on: "doc-a", language: nil),
                          note("answered", on: "doc-a", language: "es", status: .accepted),
                          note("elsewhere", on: "doc-z", language: "es")],
            unreadableDocIds: [], sequences: ["doc-a": ["aa11"]])
        let read = ResolveReader.snapshot(scope: es, annotations: walk, tasks: [],
                                          findings: ["doc-a": []], paragraphText: [:], figureOwners: [:])
        XCTAssertEqual(Set(ids(read.items)), ["note:doc-a/q-es", "note:doc-b/q-ES"])
        XCTAssertEqual(ResolveFilter.chips(read.items, passes: [], localName: "Denver"), [.questions])
    }

    /// The Source edition has no questions or changes of its own — only the
    /// book's design and compile.
    func test_theSourceEditionHasNoQuestions() {
        let walk = ProjectAnnotationsSnapshot(
            annotations: [note("q-en", on: "doc-a", language: "en"), note("q-es", on: "doc-a", language: "es")],
            unreadableDocIds: [], sequences: [:])
        XCTAssertEqual(ResolveReader.snapshot(scope: source, annotations: walk, tasks: [], findings: [:],
                                              paragraphText: [:], figureOwners: [:]).items, [])
        let read = ResolveEditionItems.Read(
            language: "en", rounds: ["doc-a": round(3, on: "doc-a", departures: [departure("d1")])],
            proposals: [proposal(.pending)], problems: [problem("Overfull box")])
        XCTAssertEqual(ids(ResolveEditionItems.items(language: "en", isSource: true,
                                                     docIds: ["doc-a"], read: read)),
                       ["design:prop-1", ResolveItem.compileProblem(problem("Overfull box")).id],
                       "the Source lists the design and the compile, never a round's changes")
    }

    // MARK: - The changes

    /// **Each chapter's changes come from its own latest finished round**:
    /// a second run on one chapter replaces that chapter's changes only; a
    /// round on a piece the book no longer holds is dropped (the map is
    /// unpruned); a cancelled round never counts.
    func test_aChaptersChangesComeFromItsOwnLatestRound() throws {
        let url = try projectURL()
        let store = TranslationRoundStore(projectURL: url)
        try store.append(round(1, on: "doc-a", departures: [departure("old")]))
        try store.append(round(2, on: "doc-b", departures: [departure("b1")]))
        try store.append(round(3, on: "doc-a", departures: [departure("new")]))
        try store.append(round(4, on: "doc-gone", departures: [departure("g1")]))
        var cancelled = round(5, on: "doc-b", departures: [departure("cancelled")])
        cancelled.legs = [.init(leg: .translate, status: .cancelled)]
        try store.append(cancelled)

        let ledger = ResolveEditionItems.readRounds(projectURL: url, language: "es", isSource: false,
                                                    docIds: ["doc-a", "doc-b"])
        let rounds = ledger.rounds
        XCTAssertEqual(rounds.mapValues(\.number), ["doc-a": 3, "doc-b": 2])
        XCTAssertEqual(ledger.newest?.number, 5, "the newest round of any outcome: the cancelled one")
        let items = ResolveEditionItems.items(language: "es", isSource: false, docIds: ["doc-a", "doc-b"],
                                              read: .init(language: "es", rounds: rounds))
        XCTAssertEqual(ids(items), ["change:es/doc-a#3/new", "change:es/doc-b#2/b1"])
        XCTAssertEqual(ResolveEditionItems.readRounds(projectURL: url, language: "es", isSource: true,
                                                      docIds: ["doc-a"]).rounds, [:], "the Source reads none")
    }

    /// A settled change (Fine, or the translator's own outcome) and an
    /// adopted or skipped glossary proposal are not listed — the Status
    /// column's predicate, the one spelling.
    func test_anAdoptedProposalIsNotListed() {
        let glossary: [TranslationRound.GlossaryProposalRecord] = [
            .init(term: "fog", rendering: "niebla", reason: "consistency", adopted: true),
            .init(term: "moor", rendering: "páramo", reason: "register", adopted: false, skipped: true),
            .init(term: "tide", rendering: "marea", reason: "the refrain", adopted: false),
        ]
        let rounds = ["doc-a": round(2, on: "doc-a",
                                     departures: [departure("open"), departure("fine", dismissed: true),
                                                  departure("rewritten", outcome: .addressed(
                                                    .init(beforeRecordId: nil, before: nil,
                                                          afterRecordId: nil, after: nil)))],
                                     glossary: glossary)]
        let items = ResolveEditionItems.items(language: "es", isSource: false, docIds: ["doc-a"],
                                              read: .init(language: "es", rounds: rounds))
        XCTAssertEqual(ids(items), ["change:es/doc-a#2/open", "glossary:es/doc-a#2/\u{AB}tide\u{BB}\u{2192}\u{AB}marea\u{BB}"],
                       "a glossary item is named by its identity, never its position")
        XCTAssertEqual(EditionStatusRows.changesToLookAt(rounds["doc-a"]!), 1,
                       "the Status column counts what the list holds")
    }

    /// The design proposal still waiting is in EVERY edition's list (the
    /// plan's call 1) — a translated edition's and the Source's — and a
    /// proposal decided is in none.
    func test_aPendingDesignProposalIsInEveryEditionsList() {
        let pending = ResolveEditionItems.Read(language: nil, proposals: [proposal(.approved, round: 2),
                                                                          proposal(.pending, round: 1)])
        for (language, isSource) in [("es", false), ("sr", false), ("en", true)] {
            var read = pending
            read.language = language
            XCTAssertEqual(ids(ResolveEditionItems.items(language: language, isSource: isSource,
                                                         docIds: ["doc-a"], read: read)),
                           ["design:prop-1"], language)
        }
        let decided = ResolveEditionItems.Read(language: "es", proposals: [proposal(.approved)])
        XCTAssertEqual(ResolveEditionItems.items(language: "es", isSource: false, docIds: [],
                                                 read: decided), [])
    }

    /// The groups: the book's own first (the design, then the problems),
    /// then each chapter in manuscript order, its questions then its
    /// changes then its glossary proposals.
    func test_theListGroupsTheBookFirstThenEachChapterQuestionsBeforeChanges() {
        let change = ResolveItem.translationChange(docId: "doc-a", language: "es", round: 3, departure("d1"))
        let glossary = ResolveItem.glossaryProposal(
            docId: "doc-a", language: "es", round: 3,
            .init(term: "fog", rendering: "niebla", reason: "", adopted: false))
        let question = ResolveItem.note(note("q", on: "doc-a", language: "es"))
        let laterQuestion = ResolveItem.note(note("q-b", on: "doc-b", language: "es"))
        let snapshot = ResolveSnapshot(
            items: [glossary, change, laterQuestion, question, .compileProblem(problem("Overfull")),
                    .designProposal(proposal(.pending))],
            sequences: ["doc-a": ["aa11"]], paragraphText: [:], unreadableDocIds: [])
        let structure = [StructureItem(id: "doc-a", title: "One", type: .document, path: "a.md"),
                         StructureItem(id: "doc-b", title: "Two", type: .document, path: "b.md")]
        let groups = ResolveGrouping.groups(snapshot, scope: es, structure: structure, sceneIndex: nil,
                                            sceneTitles: [], figureNames: [:], projectType: .novel)
        XCTAssertEqual(groups.map(\.key), [.bookLevel, .piece(docId: "doc-a"), .piece(docId: "doc-b")])
        XCTAssertEqual(groups.map(\.title), ["The book", "One", "Two"])
        XCTAssertEqual(groups[0].items.map(\.id), ["design:prop-1", ResolveItem.compileProblem(problem("Overfull")).id])
        XCTAssertEqual(groups[1].items, [question, change, glossary])
    }

    /// Each kind wears the run that replaces it, in the check's style (the
    /// design's "Two lifetimes"); a question lasts until settled.
    func test_changesDrawWithTheReplacedLifetime() {
        let change = ResolveItem.translationChange(docId: "doc-a", language: "es", round: 3, departure("d1"))
        let glossary = ResolveItem.glossaryProposal(
            docId: "doc-a", language: "es", round: 3,
            .init(term: "fog", rendering: "niebla", reason: "", adopted: false))
        XCTAssertEqual(ResolvePane.caption(for: change, localName: "Denver"),
                       ResolvePane.replacedByTheNextRoundCaption)
        XCTAssertEqual(ResolvePane.caption(for: glossary, localName: "Denver"),
                       ResolvePane.replacedByTheNextRoundCaption)
        XCTAssertEqual(ResolvePane.caption(for: .designProposal(proposal(.pending)), localName: "Denver"),
                       ResolvePane.replacedByTheNextDesignRoundCaption)
        XCTAssertEqual(ResolvePane.caption(for: .compileProblem(problem("x")), localName: "Denver"),
                       ResolvePane.replacedByTheNextCompileCaption)
        XCTAssertNil(ResolvePane.caption(for: .note(note("q", on: "doc-a", language: "es")), localName: "Denver"))
        XCTAssertFalse(change.isReplacedByTheNextCheck, "a round's change is not the check's")
    }

    // MARK: - The verbs

    /// **A change filed as a rule says the edition brief, from the write.**
    /// The round's Make it a rule answers `.filed` with the destination
    /// `RulingPerformer` returned and the round as written (the change is
    /// settled); the list says the filing through `FiledUnder`, links to that
    /// edition's Brief, and patches its round at once. The round report reads
    /// the same value, never a hard-coded Brief (ADR 0037's "Not yet built").
    func test_aChangeFiledAsARuleSaysTheEditionBrief() throws {
        let destination = FiledDestination(kind: .editionBrief("es"), scope: .project)
        var filed: [FiledDestination] = []
        var patched: [TranslationRound] = []
        var verbs = ResolveEditionVerbs()
        verbs.onFiled = { filed.append($0) }
        verbs.onRoundChanged = { patched.append($0) }
        let written = round(3, on: "doc-a", departures: [departure("d1", dismissed: true)])
        let notice = ResolveEditionActs.apply(.filed(written, destination, "Filed"), verbs: verbs)
        XCTAssertEqual(filed, [destination])
        XCTAssertEqual(patched, [written], "the settled round reaches the list and the report at once")
        XCTAssertNil(notice, "the filing is the list's one filed line, not the row's")

        let sentence = FiledUnder.sentence(destination, faces: .edition(language: "es"), structure: [],
                                           projectType: .novel, firstReaderName: nil)
        XCTAssertEqual(sentence, "Filed under the "
                       + LanguageName.labelled("es") + " edition brief")
        XCTAssertEqual(FiledUnder.brief(of: destination), .edition(language: "es"))

        // Fine changes the record: patched, and the row says so.
        let fine = ResolveEditionActs.apply(.done(written, TranslationRoundReport.dismissedLine), verbs: verbs)
        XCTAssertEqual(patched.count, 2)
        XCTAssertEqual(fine, TranslationRoundReport.dismissedLine)
        XCTAssertEqual(ResolveEditionActs.apply(.refused("No."), verbs: verbs), "No.")
        XCTAssertEqual(ResolveEditionActs.apply(nil, verbs: verbs), TranslationRoundReport.rowGone)

        let report = SourceScan.codeLines(of: try SourceTree.read(
            "Maugham/Views/Publish/TranslationRoundReportView.swift")).joined(separator: "\n")
        XCTAssertTrue(report.contains("brief: FiledUnder.brief(of: destination)"),
                      "the report links to the Brief the write named")
        XCTAssertFalse(report.contains("brief: .edition(language: round.language)"),
                       "the report's hard-coded filing line is gone")
    }

    /// The design row's verbs: the gate's Approve and Discard, only while the
    /// proposal waits and only where this Mac may decide the design.
    func test_aDesignProposalOffersApproveAndDiscardOnlyWhileItWaits() {
        XCTAssertEqual(EditionDesignRow.verbs(status: .pending, mayDecide: true), [.approve, .discard])
        XCTAssertEqual(EditionDesignRow.verbs(status: .pending, mayDecide: false), [],
                       "a Mac that may not decide the design is offered neither")
        for status: DesignProposalStore.Status in [.approved, .rejected, .superseded, .unknown("later")] {
            XCTAssertEqual(EditionDesignRow.verbs(status: status, mayDecide: true), [], "\(status)")
        }
        XCTAssertEqual(EditionDesignRow.Verb.approve.title, DesignGate.Verb.approve.title,
                       "the gate's own word, never re-spelled")
    }

    /// Discard turns a waiting proposal down and moves no live byte;
    /// anything but a waiting proposal is refused.
    func test_discardTurnsAWaitingProposalDown() throws {
        let url = try projectURL()
        let store = DesignProposalStore(projectURL: url)
        let staged = try store.stage(report: DesignerReport(specMarkdown: "A quiet page.", files: [
            .init(path: "template.tex", content: "% tex")]), round: 1, designerName: "Tschichold",
                                     language: nil)
        guard case .done(let discarded, _) = DesignGatePromotion.discard(staged, projectURL: url) else {
            return XCTFail("Discard was refused over a waiting proposal")
        }
        XCTAssertEqual(discarded.status, .rejected)
        XCTAssertEqual(try store.load(id: staged.id).status, .rejected, "the record on disk agrees")
        guard case .refused(let sentence) = DesignGatePromotion.discard(discarded, projectURL: url) else {
            return XCTFail("a decided proposal was discarded again")
        }
        XCTAssertEqual(sentence, DesignGate.notPendingRefusal)
    }

    // MARK: - The head

    /// Run is drawn where this Mac's translator may translate any piece of
    /// the book — the desk's rule, asked of the translator actor; with no
    /// piece, the book's own stream answers.
    func test_theEditionHeadOffersRunWhereTheTranslatorMay() {
        XCTAssertTrue(EditionHeadView.offersRun(docIds: ["doc-a", "doc-b"], mayTranslate: { $0 == "doc-b" }))
        XCTAssertFalse(EditionHeadView.offersRun(docIds: ["doc-a", "doc-b"], mayTranslate: { _ in false }),
                       "a reviewer who may translate nothing sees no Run")
        XCTAssertTrue(EditionHeadView.offersRun(docIds: [], mayTranslate: {
            $0 == DocumentClass.projectStreamDocId }))
        XCTAssertEqual(ResolveHead.shape(es), .edition(language: "es", isSource: false))
    }

    /// The head's letter: the newest round that says something — its
    /// summary, else the collator's verdict — across the chapters' latest
    /// rounds; signed, with its chapter and day.
    func test_theHeadCarriesTheTranslatorsNewestLetter() {
        var quiet = round(9, on: "doc-b")
        quiet.summary = "  "
        var collated = round(4, on: "doc-c")
        collated.collatorOverall = "Holds well."
        let rounds = ["doc-a": round(3, on: "doc-a", summary: "I kept the fog."),
                      "doc-b": quiet, "doc-c": collated]
        let newest = ResolveEditionItems.newestLetter(rounds)
        XCTAssertEqual(newest?.number, 4, "a round with nothing to say is not the letter")
        XCTAssertEqual(newest.flatMap(ResolveEditionItems.letter(of:)), "Holds well.")
        XCTAssertEqual(ResolveEditionItems.letter(of: rounds["doc-a"]!), "I kept the fog.")
        let signature = ResolveEditionItems.signature(translator: "Lucía", chapter: "Three", round: collated)
        XCTAssertTrue(signature.hasPrefix("\u{2014} Lucía \u{00B7} Three \u{00B7} round 4"), signature)
        XCTAssertNil(ResolveEditionItems.newestLetter([:]))
    }

    /// The Source edition's head is the designer's (Denver, 2026-11-21,
    /// answer 1): the shape says so, and its line, Run and refusals are the
    /// desk's design row's, resolved from the same values.
    func test_theSourceHeadOffersADesignRound() {
        XCTAssertEqual(ResolveHead.shape(source), .edition(language: "en", isSource: true))
        let idle = DesignRoundState.resolve(designerName: "Tschichold", proposals: [proposal(.pending)],
                                               runState: .idle, session: .free, hasOpenProposalRound: true)
        XCTAssertTrue(idle.canRun)
        XCTAssertTrue(idle.offersRequestChanges)
        XCTAssertTrue(idle.offersShow)
        let busy = DesignRoundState.resolve(designerName: "Tschichold", proposals: [],
                                               runState: .running(round: 2, language: nil),
                                               session: .busy(round: 2), hasOpenProposalRound: false)
        XCTAssertFalse(busy.canRun)
        XCTAssertTrue(busy.isRunning, "Cancel is drawn while a round runs")
        XCTAssertEqual(busy.latestLine, DesignRoundState.noRoundYet)
    }

    /// What an empty edition says: the next step where nothing has run, the
    /// state of things where everything is settled.
    func test_anEmptyEditionSaysSomethingTrue() {
        let never = ResolveEditionItems.clearLine(language: "es", isSource: false, hasRounds: false)
        let settled = ResolveEditionItems.clearLine(language: "es", isSource: false, hasRounds: true)
        let design = ResolveEditionItems.clearLine(language: "en", isSource: true, hasRounds: false)
        XCTAssertTrue(never.contains("No round has run"), never)
        XCTAssertTrue(settled.contains("nothing from the latest rounds is left to look at"), settled)
        XCTAssertTrue(design.contains("design"), design)
        XCTAssertEqual(ResolvePane.emptyState(scope: es, hasItems: false, hasVisible: false,
                                              offersColdStart: false, editionClear: never),
                       .editionClear(never))
        XCTAssertEqual(ResolvePane.emptyState(scope: es, hasItems: true, hasVisible: false,
                                              offersColdStart: false, editionClear: never), .filteredOut)
    }

    // MARK: - The keys

    /// **⌘⌥A, ⌘⌥D and ⌘⌥T apply with an edition on the faces**: the key is
    /// handed over (`positionAsk` keeps the filter on every ground), and a
    /// filter whose chip the edition does not have selects nothing — the
    /// writer's selection stands, and the request is spent, never left to
    /// fire later. Questions selects its chip.
    func test_keyFiltersApplyWithAnEditionOnTheFaces() throws {
        let chips: [ResolveSource] = [.questions, .changes, .design, .compile]
        for key in [ResolveKeyFilter.rounds, .checks, .mine] {
            let info: [AnyHashable: Any] = [MaughamEvent.positionKey: RightColumnPosition.resolve.rawValue,
                                            MaughamEvent.resolveFilterKey: key.rawValue]
            XCTAssertEqual(ProjectWindow.positionAsk(in: info, shows: .resolve).request, .filter(key))
            let outcome = ResolvePane.apply(.filter(key), groups: [], sceneIndex: nil, chips: chips, activePassId: nil,
                                            dense: false, selection: [.changes], choices: [:])
            XCTAssertEqual(outcome.selection, [.changes], "\(key) leaves the writer's filter as it was")
        }
        let questions = ResolvePane.apply(.filter(.questions), groups: [], sceneIndex: nil, chips: chips, activePassId: nil,
                                          dense: false, selection: [], choices: [:])
        XCTAssertEqual(questions.selection, [.questions])
        XCTAssertEqual(ResolveFilter.chips([.compileProblem(problem("x")), .designProposal(proposal(.pending)),
                                            .translationChange(docId: "doc-a", language: "es", round: 1,
                                                               departure("d")),
                                            .note(note("q", on: "doc-a", language: "es"))],
                                           passes: [], localName: "Denver"),
                       chips, "the chips appear only when present, in the column's order")
        // The list spends a request the moment it takes it.
        let pane = SourceScan.codeLines(of: try SourceTree.read(
            "Maugham/Views/Resolve/ResolvePane.swift")).joined(separator: "\n")
        XCTAssertTrue(pane.contains("guard let new else { return }\n        request = nil"),
                      "take(_:) clears the request before anything else")
    }

    // MARK: - Censuses

    /// The desk is gone (shell p4 Task 7): no production file is the desk or
    /// mounts it, and the column's desk view is gone.
    func test_theDeskIsGone() throws {
        let sources = try SourceTree.sources(under: "Maugham")
        XCTAssertFalse(sources.isEmpty, "premise: the census reads the app")
        func offenders(_ files: [(path: String, text: String)]) -> [String] {
            files.filter { file in
                (file.path as NSString).lastPathComponent.hasPrefix("DepartmentPane")
                    || SourceScan.codeLines(of: file.text).joined(separator: "\n").contains("DepartmentPaneHost(")
            }.map(\.path)
        }
        XCTAssertEqual(offenders(sources), [])
        XCTAssertFalse(sources.contains { SourceScan.codeLines(of: $0.text).joined().contains("struct RightColumnDesk") })
        // The planted control: a mount is caught; a mention in a comment is not.
        XCTAssertEqual(offenders([("Planted.swift", "let desk = DepartmentPaneHost(store: store)"),
                                  ("Comment.swift", "/// the desk was `DepartmentPaneHost(`")]),
                       ["Planted.swift"])
    }

    /// No edition source loads a document: the edition read and the rows'
    /// file are read by `ResolveReaderTests`' census.
    func test_noEditionSourceLoadsADocument() throws {
        let text = try SourceTree.read("Maugham/Views/Resolve/ResolveEditionItems.swift")
        XCTAssertEqual(ResolveReaderTests.offenders(in: ["ResolveEditionItems.swift": text]), [])
        XCTAssertTrue(text.contains("currentParagraphState("),
                      "premise: the change rows' sources come from the derived state, never a load")
        let planted = text + "\nlet d = try await Document.load(x)"
        XCTAssertEqual(ResolveReaderTests.offenders(in: ["ResolveEditionItems.swift": planted]),
                       ["ResolveEditionItems.swift: Document.load("])
    }

    // MARK: - The tree's mark

    /// An edition row carries the mark while its list holds anything:
    /// every edition while a design proposal waits or the compile left
    /// problems; a translated edition while its language has a question or
    /// its latest rounds leave something. The Source never for a round.
    func test_anEditionRowIsMarkedWhileItsListHoldsAnything() {
        let editions: [(language: String, isSource: Bool)] = [("en", true), ("es", false), ("sr", false)]
        XCTAssertEqual(ResolveEditionItems.markedEditions(editions: editions, questionLanguages: [],
                                                          roundsLeaveSomething: [], bookLevel: false), [])
        XCTAssertEqual(ResolveEditionItems.markedEditions(editions: editions, questionLanguages: ["es"],
                                                          roundsLeaveSomething: ["sr"], bookLevel: false),
                       ["es", "sr"])
        XCTAssertEqual(ResolveEditionItems.markedEditions(editions: editions, questionLanguages: ["en"],
                                                          roundsLeaveSomething: ["en"], bookLevel: false),
                       [], "the Source holds no questions or changes")
        XCTAssertEqual(ResolveEditionItems.markedEditions(editions: editions, questionLanguages: [],
                                                          roundsLeaveSomething: [], bookLevel: true),
                       ["en", "es", "sr"])
        var marks = ResolvePresence.Marks.none
        marks.editions = ["es"]
        XCTAssertEqual(ResolvePresence.rowMark(.edition("es"), in: marks), .something)
        XCTAssertEqual(ResolvePresence.rowMark(.edition("sr"), in: marks), .quiet)

        let open = ResolveSnapshot(items: [.note(note("q", on: "doc-a", language: "ES")),
                                           .note(note("fig", on: "fig-aaaa1111", language: "fr")),
                                           .note(note("done", on: "doc-a", language: "sr", status: .accepted))],
                                   sequences: [:], paragraphText: [:], unreadableDocIds: [])
        XCTAssertEqual(ResolveEditionItems.questionLanguages(open), ["es"])
        XCTAssertTrue(ResolveEditionItems.leavesSomething(round(1, on: "doc-a", departures: [departure("d")])))
        XCTAssertFalse(ResolveEditionItems.leavesSomething(round(1, on: "doc-a",
                                                                 departures: [departure("d", dismissed: true)])))
    }

    /// The edition rows draw the mark through `rowMark`, and the window's
    /// watch publishes the editions' half without a walk of its own.
    func test_theEditionRowsAndTheWatchAreWired() throws {
        let rows = SourceScan.codeLines(of: try SourceTree.sourceOfType("TreeEditionRows", under: ["Maugham"]))
            .joined(separator: "\n")
        XCTAssertTrue(rows.contains("ResolvePresenceMark(ResolvePresence.rowMark(.edition(row.language), in: presence))"))
        let watch = SourceScan.codeLines(of: try SourceTree.sourceOfType("ResolvePresenceWatch", under: ["Maugham"]))
            .joined(separator: "\n")
        for token in ["marks.editions = ResolveEditionItems.markedEditions(",
                      "marks.proposedBriefs = proposedBriefs",
                      "ResolveEditionItems.questionLanguages(reader.snapshot)",
                      "Task.detached(priority: .utility)",
                      "ResolveEditionItems.languagesLeavingSomething("] {
            XCTAssertTrue(watch.contains(token), token)
        }
        let window = try SourceTree.windowSource()
        XCTAssertTrue(window.contains(
            "compileProblems: !ResolveEditionItems.stoppingProblems(publishCentre.compileRunner.state).isEmpty"),
                      "the window hands the presence its compile's problems")
    }

    // MARK: - Fix round: the head's newest round, the "Proposed" mark

    /// **The head says why the newest round stopped** (fix round I3): a
    /// finished newest round adds nothing; a failed or cancelled one is said
    /// in its own words above the last finished letter, which is then the
    /// earlier one; while a round runs, its own leg line speaks instead.
    func test_theHeadSaysWhyTheNewestRoundStopped() {
        let lettered = round(3, on: "doc-a", summary: "I kept the rain.")
        let rounds = ["doc-a": lettered]
        let now = t.addingTimeInterval(3 * 3600)

        // Finished: nothing stopped, the letter is current.
        let finished = ResolveEditionItems.headRounds(newest: lettered, rounds: rounds, running: false, now: now)
        XCTAssertEqual(finished, .init(letter: lettered))

        // Failed while translating, with its reason, newer than the letter.
        var failed = round(4, on: "doc-b")
        failed.legs = [.init(leg: .translate, status: .failed, reason: "Claude couldn't be reached")]
        let afterFailure = ResolveEditionItems.headRounds(newest: failed, rounds: rounds, running: false, now: now)
        XCTAssertEqual(afterFailure.stopped, failed)
        XCTAssertEqual(afterFailure.stoppedLine, TranslationRunState.roundLine(failed, now: now))
        XCTAssertTrue(afterFailure.stoppedLine?.contains("failed while translating \u{2014} Claude couldn't be reached") ?? false,
                      afterFailure.stoppedLine ?? "")
        XCTAssertEqual(afterFailure.letter, lettered)
        XCTAssertTrue(afterFailure.letterIsEarlier, "last week's letter is labelled the earlier one")

        // Cancelled.
        var cancelled = round(5, on: "doc-a")
        cancelled.legs = [.init(leg: .read, status: .cancelled)]
        let afterCancel = ResolveEditionItems.headRounds(newest: cancelled, rounds: rounds, running: false, now: now)
        XCTAssertTrue(afterCancel.stoppedLine?.contains("cancelled while reading") ?? false)
        XCTAssertTrue(afterCancel.letterIsEarlier)

        // Running: the stopped line gives way to the run's own.
        XCTAssertEqual(ResolveEditionItems.headRounds(newest: failed, rounds: rounds, running: true, now: now),
                       .init(letter: lettered))

        // A failed round's own partial letter is not "earlier".
        var partial = failed
        partial.summary = "Half of it."
        let ownLetter = ResolveEditionItems.headRounds(newest: partial, rounds: ["doc-b": partial],
                                                       running: false, now: now)
        XCTAssertEqual(ownLetter.letter, partial)
        XCTAssertFalse(ownLetter.letterIsEarlier)
    }

    /// **The head's read carries the newest round of any outcome** — one
    /// decode with the finished map — and only the book's own pieces'.
    func test_theReadCarriesTheNewestRoundOfAnyOutcome() throws {
        let url = try projectURL()
        let store = TranslationRoundStore(projectURL: url)
        try store.append(round(1, on: "doc-a", summary: "ok"))
        var failed = round(2, on: "doc-a")
        failed.legs = [.init(leg: .translate, status: .failed, reason: "no")]
        try store.append(failed)
        XCTAssertEqual(ResolveEditionItems.readRounds(projectURL: url, language: "es", isSource: false,
                                                      docIds: ["doc-a"]).newest?.number, 2)
        try store.append(round(3, on: "doc-gone"))
        XCTAssertEqual(ResolveEditionItems.readRounds(projectURL: url, language: "es", isSource: false,
                                                      docIds: ["doc-a"]).newest, nil,
                       "a round on a piece the book no longer holds is not the head's")
    }

    /// **The edition's row carries "Proposed" while a brief proposal waits**
    /// (fix round I4), beside — never instead of — the dot; only an edition
    /// row has it. And Brief's segment dot is lit for the faced edition.
    func test_aProposedBriefMarksItsEditionsRowAndBrief() throws {
        let proposals: [StatementProposalStore.Proposal] = [
            .init(kind: .editionBrief("ES"), markdown: "x", rationale: nil, proposedAt: t, author: "Claude"),
            .init(kind: .visualLanguage, markdown: "x", rationale: nil, proposedAt: t, author: "Claude"),
        ]
        var marks = ResolvePresence.Marks.none
        marks.proposedBriefs = ResolvePresence.proposedBriefLanguages(proposals)
        XCTAssertEqual(marks.proposedBriefs, ["es"])
        XCTAssertTrue(ResolvePresence.proposalMark(.edition("es"), in: marks))
        XCTAssertFalse(ResolvePresence.proposalMark(.edition("sr"), in: marks))
        XCTAssertFalse(ResolvePresence.proposalMark(.book, in: marks))
        XCTAssertEqual(ResolvePresence.rowMark(.edition("es"), in: marks), .quiet,
                       "the proposal is its own word, not the something-to-resolve dot")
        XCTAssertEqual(ProposedBriefBadge.title, "Proposed")
        XCTAssertTrue(RightColumnControl.briefProposalPending(
            visualLanguage: false, editionBriefs: ["es"], faces: .edition(language: "ES")))
        XCTAssertFalse(RightColumnControl.briefProposalPending(
            visualLanguage: false, editionBriefs: ["es"], faces: .edition(language: "sr")))
        XCTAssertFalse(RightColumnControl.briefProposalPending(
            visualLanguage: false, editionBriefs: ["es"], faces: .item("ch-1")))
        XCTAssertTrue(RightColumnControl.briefProposalPending(
            visualLanguage: true, editionBriefs: [], faces: .project))

        // Wired: the row reads the mark, the watch reads the proposals and
        // hears their event, the control reads them for Brief's dot.
        let rows = SourceScan.codeLines(of: try SourceTree.sourceOfType("TreeEditionRows", under: ["Maugham"]))
            .joined(separator: "\n")
        XCTAssertTrue(rows.contains("if ResolvePresence.proposalMark(.edition(row.language), in: presence) {"))
        let watch = SourceScan.codeLines(of: try SourceTree.sourceOfType("ResolvePresenceWatch", under: ["Maugham"]))
            .joined(separator: "\n")
        for token in ["marks.proposedBriefs = proposedBriefs",
                      "proposedBriefs = ResolvePresence.proposedBriefLanguages(",
                      ".onProjectEvent(.maughamStatementProposalsChanged, url: url, window: window)"] {
            XCTAssertTrue(watch.contains(token), token)
        }
        let control = SourceScan.codeLines(of: try SourceTree.sourceOfType("RightColumnControl", under: ["Maugham"]))
            .joined(separator: "\n")
        XCTAssertTrue(control.contains("editionBriefs: $editionBriefsProposed"))
    }

    /// **Run Whole Book says what it will cost** (fix round I2): the figure
    /// on the scope line and in the help, or the refusal in its place; taken
    /// only while no round runs.
    func test_runWholeBookSaysWhatItWillCost() {
        XCTAssertEqual(ResolveEditionItems.runScopeLine(count: 12, imprint: "Volume One", preflight: .words(84_000)),
                       "Runs the 12 chapters of \u{201C}Volume One\u{201D}, the imprint chosen above the book"
                       + " \u{00b7} 7 legs \u{00b7} ~84,000 words briefed.")
        XCTAssertEqual(ResolveEditionItems.runScopeLine(count: 3, imprint: nil, preflight: .words(900)),
                       "Runs every chapter of the book: 3 chapters \u{00b7} 7 legs \u{00b7} ~900 words briefed.")
        XCTAssertEqual(ResolveEditionItems.runScopeLine(count: 3, imprint: nil, preflight: .unreadable("x.json won't read")),
                       "Runs every chapter of the book: 3 chapters \u{00b7} x.json won't read.")
        XCTAssertEqual(ResolveEditionItems.runScopeLine(count: 3, imprint: nil),
                       "Runs every chapter of the book: 3 chapters.", "no figure yet: no clause")
        XCTAssertTrue(TranslationPreflight.refillsBudgets(pipeline: .idle))
        XCTAssertFalse(TranslationPreflight.refillsBudgets(
            pipeline: .running(docId: "d", language: "es", leg: .translate, book: nil)))
    }

    /// **The edition's figure is `budget`'s, read off the main actor and
    /// cached** (fix round I2): the same words the main-actor door counts; a
    /// second read over the unchanged book counts nothing; a translation
    /// written moves it.
    func test_theEditionFigureIsBudgetsReadOffTheMainActorAndCached() async throws {
        let book = try await ResolvePresenceTests.book(in: TestTemp.root, chapters: 3, noted: [0, 1, 2])
        let reference = try await TranslationPreflight.budget(
            documentIds: book.ids, language: "es", store: book.store,
            documentStore: book.documentStore, projectURL: book.url)
        let first = await TranslationPreflight.editionBudget(
            documentIds: book.ids, language: "es", store: book.store, documentStore: book.documentStore)
        XCTAssertEqual(first, reference.map { .words($0) }, "the main-actor door's own figure")
        let counted = EditionBudgetCache.computed
        let again = await TranslationPreflight.editionBudget(
            documentIds: book.ids, language: "es", store: book.store, documentStore: book.documentStore)
        XCTAssertEqual(again, first)
        XCTAssertEqual(EditionBudgetCache.computed, counted, "an unchanged book is not read again")

        let state = try book.store.derivedCache.state(forDocId: book.ids[0], in: book.url)
        let paragraph = try XCTUnwrap(state.sequence.first)
        try await TranslationStore.append(
            TranslationRecord(paragraphId: paragraph, language: "es", text: "Capítulo cero, con muchas palabras más.",
                              sourceHash: TranslationHash.hash(state.paragraphs[paragraph] ?? ""), verbatim: false),
            forDocId: book.ids[0], identity: LocalIdentities.current.translator, identities: .current,
            in: book.url)
        let after = await TranslationPreflight.editionBudget(
            documentIds: book.ids, language: "es", store: book.store, documentStore: book.documentStore)
        let fresh = try await TranslationPreflight.budget(
            documentIds: book.ids, language: "es", store: book.store,
            documentStore: book.documentStore, projectURL: book.url)
        XCTAssertEqual(after, fresh.map { .words($0) }, "a translation written moves the figure")
        XCTAssertEqual(EditionBudgetCache.computed, counted + 1)
        await book.documentStore.close()
    }

    // MARK: - Mounted: an edition faced shows its own list

    private var fixtures: [StatementMountFixture] = []
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        await waitOut(0.05)
        windows.removeAll()
        for fixture in fixtures { await fixture.closeAndTearDown() }
        fixtures.removeAll()
        try await super.tearDown()
    }

    private func everythingRead(in window: NSWindow) throws -> Set<String> {
        var read = Set(try axTexts(in: window))
        read.formUnion(try axButtonLabels(in: window))
        for element in try axElements(in: window) {
            for attribute in ["accessibilityHelp", "accessibilityLabel", "accessibilityTitle",
                              "accessibilityValue"] {
                if let value = axAttribute(element, attribute) as? String, !value.isEmpty {
                    read.insert(value)
                }
            }
        }
        return read
    }

    /// **The Spanish edition faced**: To resolve's own list, headed by the
    /// translator's newest letter, listing the chapter's change — built the
    /// way production builds the column.
    func test_aTranslatedEditionFacedShowsItsHeadAndItsChanges() async throws {
        try requireAssistiveClient()
        let f = try await StatementMountFixture.novel(named: "EditionList")
        fixtures.append(f)
        try TranslationRoundStore(projectURL: f.store.url).append(
            round(2, on: f.documentItemId, departures: [departure("d1")], summary: "I kept the fog."))
        let probe = RightColumnFixture.Probe(
            position: .resolve,
            subject: WindowSubject(open: .edition(language: "es"), faces: .edition(language: "es")))
        let window = TestWindow.mount(
            RightColumnFixture.pane(store: f.store, documentStore: f.documentStore, probe: probe)
                .environment(f.preferences),
            size: CGSize(width: 320, height: 800))
        windows.append(window)
        let wanted = ["I kept the fog.", "it now says she whispers", ResolvePane.replacedByTheNextRoundCaption,
                      ResolveEditionItems.openTheReportTitle]
        let found = await pumpUntil(deadline: 5) {
            let read = (try? self.everythingRead(in: window)) ?? []
            return wanted.allSatisfy(read.contains)
        }
        let read = try everythingRead(in: window)
        XCTAssertTrue(found, "the edition's list did not draw \(wanted.filter { !read.contains($0) }); it reads \(read)")
        XCTAssertFalse(read.contains("New To-do"), "an edition lists no to-dos, so it makes none")
    }

    /// **The Source edition faced**: the designer's head — the direction
    /// field and Run a design round — and the empty line that says so.
    func test_theSourceEditionFacedShowsTheDesignersHead() async throws {
        try requireAssistiveClient()
        let f = try await StatementMountFixture.novel(named: "SourceEditionList")
        fixtures.append(f)
        let probe = RightColumnFixture.Probe(
            position: .resolve,
            subject: WindowSubject(open: .edition(language: "en"), faces: .edition(language: "en")))
        let window = TestWindow.mount(
            RightColumnFixture.pane(store: f.store, documentStore: f.documentStore, probe: probe)
                .environment(f.preferences),
            size: CGSize(width: 320, height: 800))
        windows.append(window)
        let wanted = [DesignRoundState.runAccessibilityLabel,
                      ResolveEditionItems.clearLine(language: "en", isSource: true, hasRounds: false)]
        let found = await pumpUntil(deadline: 5) {
            let read = (try? self.everythingRead(in: window)) ?? []
            return wanted.allSatisfy(read.contains)
        }
        let read = try everythingRead(in: window)
        XCTAssertTrue(found, "the Source's head did not draw \(wanted.filter { !read.contains($0) }); it reads \(read)")
        XCTAssertTrue(try axIdentifiers(in: window).contains("resolve.edition.direction"),
                      "the direction field is drawn")
    }
}

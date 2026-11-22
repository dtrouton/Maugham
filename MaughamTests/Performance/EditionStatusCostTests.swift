import XCTest
import MaughamCore
@testable import Maugham

/// **What an edition's Status read costs a book** (shell p4 Task 5, fix round
/// 1, the review's I4). Every chapter is closed, each has one Spanish
/// paragraph and one open note, and the edition is Spanish.
///
/// - **before**: `EditionStatus.documentRows` as `translation_status` calls it
///   — every closed chapter transient-loaded on the main actor to count its
///   questions, every language derived;
/// - **after**: the questions handed in from the window's presence read (read
///   off the main actor by the walk the window already runs, so not timed
///   here), Spanish only, a yield between chapters.
///
/// Each figure is the call's wall time on the main actor and its longest
/// single main-actor step. Before the fix the whole call is one step for
/// timing purposes only where nothing yields; each chapter's load is awaited,
/// so the "longest step" there is measured per chapter as one-chapter calls.
///
/// **Env-gated and kept**, `ResolvePresenceCostTests`' rule: heavy, a
/// measurement, nothing asserted about a duration. Run it with:
///
///     TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1 ./scripts/test.sh only EditionStatusCostTests
@MainActor
final class EditionStatusCostTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        temp.cleanup()
        temp = nil
    }

    private func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private struct Cost {
        var wall = 0.0
        var longest = 0.0
        var text: String { String(format: "wall %.1f ms, longest one-chapter step %.1f ms", wall, longest) }
    }

    private func measure(_ ids: [String], store: ProjectStore,
                         options: EditionStatus.ReadOptions) async -> (Cost, EditionStatus.DocumentReport) {
        let clock = ContinuousClock()
        var report: EditionStatus.DocumentReport?
        let start = clock.now
        report = await EditionStatus.documentRows(documentIds: ids, store: store,
                                                  projectURL: store.url, options: options)
        var cost = Cost(wall: ms(clock.now - start))
        // Each chapter alone: the most a single chapter holds the main actor.
        for id in ids.prefix(20) {
            let one = clock.now
            _ = await EditionStatus.documentRows(documentIds: [id], store: store,
                                                 projectURL: store.url, options: options)
            cost.longest = max(cost.longest, ms(clock.now - one))
        }
        return (cost, report!)
    }

    private func probe(chapters: Int) async throws -> String {
        let book = try await ResolvePresenceTests.book(in: temp.url, chapters: chapters,
                                                       noted: Set(0..<chapters))
        for id in book.ids {
            let state = try book.store.derivedCache.state(forDocId: id, in: book.url)
            let first = try XCTUnwrap(state.sequence.first)
            try await TranslationStore.append(
                TranslationRecord(paragraphId: first, language: "es", text: "Uno.",
                                  sourceHash: TranslationHash.hash(state.paragraphs[first] ?? ""),
                                  verbatim: false),
                forDocId: id, identity: LocalIdentities.current.translator, identities: .current,
                in: book.url)
        }
        let (before, loaded) = await measure(book.ids, store: book.store, options: .init())
        // The presence read's answer, computed here once and not timed: the
        // window reads it off the main actor whether or not Status shows.
        let questions = EditionStatus.openQuestions(in: book.store.listAnnotationsAcrossProject())
        let (after, handed) = await measure(
            book.ids, store: book.store,
            options: .init(openQuestions: questions, languages: ["es"], yieldsAndStops: true))
        XCTAssertEqual(handed.rows, loaded.rows.filter { $0.language == "es" })
        await book.documentStore.close()
        return "\(chapters) chapters — before: \(before.text); after: \(after.text)"
    }

    /// **What an edition's To resolve read costs a book** (shell p4 Task 6):
    /// every chapter closed, each with a finished Spanish round leaving one
    /// change, so the read quotes every chapter's source paragraph. Its wall
    /// time and its longest single main-actor step (a one-chapter read; the
    /// whole read yields between chapters).
    private func toResolveProbe(chapters: Int) async throws -> String {
        let book = try await ResolvePresenceTests.book(in: temp.url, chapters: chapters,
                                                       noted: Set(0..<chapters))
        let rounds = TranslationRoundStore(projectURL: book.url)
        for (index, id) in book.ids.enumerated() {
            let first = try XCTUnwrap(try book.store.derivedCache.state(forDocId: id, in: book.url)
                .sequence.first)
            var round = TranslationRound(number: index + 1, language: "es", docId: id, startedAt: Date())
            round.endedAt = Date()
            round.departures = [.init(id: "d\(index)", paragraphId: first, verdict: "drifted", kind: "tone",
                                      note: "softer", gloss: "it whispers", outcome: nil)]
            try rounds.append(round)
        }
        let clock = ContinuousClock()
        let start = clock.now
        let read = await ResolveEditionItems.read(language: "es", isSource: false, docIds: book.ids,
                                                  problems: [], store: book.store,
                                                  documentStore: book.documentStore)
        var cost = Cost(wall: ms(clock.now - start))
        XCTAssertEqual(read.departureRows.count, chapters, "premise: every chapter's change is quoted")
        for id in book.ids.prefix(20) {
            let one = clock.now
            _ = await ResolveEditionItems.read(language: "es", isSource: false, docIds: [id], problems: [],
                                               store: book.store, documentStore: book.documentStore)
            cost.longest = max(cost.longest, ms(clock.now - one))
        }
        await book.documentStore.close()
        return "\(chapters) chapters — \(cost.text)"
    }

    /// **Selecting an edition, then switching between two** (shell p4 Task 6
    /// fix round, review I4): Spanish, French, Spanish over a closed book.
    /// - **before**: the list's read as Task 6 shipped it — each edition a
    ///   scope of its own, so each selection asked the annotation and task
    ///   walks on the main actor (a fresh hold per scope);
    /// - **after**: the questions from the window's presence read (read off
    ///   the main actor by the walk the window already runs, so not timed).
    /// Each figure: the three selections' total, and the longest single
    /// main-actor step (each `refreshed` is one).
    private func switchProbe(chapters: Int) async throws -> String {
        let book = try await ResolvePresenceTests.book(in: temp.url, chapters: chapters,
                                                       noted: Set(0..<chapters))
        let clock = ContinuousClock()
        let editions = ["es", "fr", "es"].map {
            ResolveScope.edition(language: $0, isSource: false, docIds: book.ids)
        }
        func run(presence: ResolvePresence.BookReading?) -> Cost {
            var cost = Cost()
            for scope in editions {
                var walks = ResolveWalkHold()
                let key = ResolvePane.readKey(scope: scope, annotationsToken: 0, store: book.store,
                                              documentStore: book.documentStore, diagnostics: nil,
                                              localName: "", presence: presence, figureChanges: [])
                let start = clock.now
                _ = ResolvePane.refreshed(.empty, step: .read, key: key, walks: &walks, presence: presence,
                                          store: book.store, documentStore: book.documentStore,
                                          diagnostics: nil)
                let step = ms(clock.now - start)
                cost.wall += step
                cost.longest = max(cost.longest, step)
            }
            return cost
        }
        let before = run(presence: nil)
        let reading = ResolvePresence.bookReading(ResolveReader.read(
            scope: ResolveScope.of(.project, readIn: nil, sourceLanguage: "en",
                                   structure: book.store.manifest.structure, projectType: .novel),
            store: book.store, documentStore: book.documentStore, diagnostics: nil, figureChanges: []))
        let after = run(presence: reading)
        await book.documentStore.close()
        return "\(chapters) chapters, es → fr → es — before: \(before.text); after: \(after.text)"
    }

    /// **What one verb costs the main actor** (shell p4 Task 6 fix round 2,
    /// N5): a book of `chapters` closed chapters, each with a finished
    /// Spanish round of ten departures, ten notes and five glossary
    /// proposals (the ledger's size at that book). Timed on the main actor:
    /// Fine (one decode + one encode), Adopt (a decode to decide, a ruling,
    /// a decode + encode), and the reads the announcement sets off — the
    /// edition's Status (rounds and trends) and the centre's re-read.
    private func verbProbe(chapters: Int) async throws -> String {
        let book = try await ResolvePresenceTests.book(in: temp.url, chapters: chapters, noted: [])
        let rounds = TranslationRoundStore(projectURL: book.url)
        let words = String(repeating: "The translation moves the weight of the clause. ", count: 6)
        for (index, id) in book.ids.enumerated() {
            var round = TranslationRound(number: index + 1, language: "es", docId: id, startedAt: Date())
            round.endedAt = Date()
            round.summary = words
            round.departures = (0..<10).map {
                .init(id: "d\($0)", paragraphId: "p\($0)", verdict: "drifted", kind: "tone",
                      note: words, gloss: words, outcome: nil)
            }
            round.notes = (0..<10).map {
                .init(id: "n\($0)", leg: .read, author: "reader", paragraphId: "p\($0)", kind: "flow",
                      severity: nil, text: words, outcome: nil)
            }
            round.glossaryProposals = (0..<5).map {
                .init(term: "term \($0)", rendering: "término \($0)", reason: words, adopted: false)
            }
            try rounds.append(round)
        }
        let size = (try? FileManager.default.attributesOfItem(
            atPath: TranslationRoundStore.fileURL(language: "es", in: book.url).path)[.size] as? Int) ?? 0
        let actions = TranslationRoundActions.production(store: book.store, documentStore: book.documentStore,
                                                         projectURL: book.url, world: nil)
        let target = try XCTUnwrap(rounds.latestFinished(language: "es", docId: book.ids[0]))
        // Before the fix: each read as one synchronous main-actor step.
        let clock = ContinuousClock()
        var start = clock.now
        _ = try rounds.mutate(language: "es", docId: book.ids[1], number: 2) { $0.departures[0].dismissed = true }
        let fineBefore = ms(clock.now - start)
        start = clock.now
        _ = rounds.latestFinishedByPiece(language: "es")
        _ = rounds.trendsByPiece(language: "es")
        let statusBefore = ms(clock.now - start)
        start = clock.now
        _ = rounds.record(language: "es", docId: book.ids[0], number: 1)
        let centreBefore = ms(clock.now - start)
        // After: the longest main-actor stall while each runs as it now does
        // (the heartbeat's own floor first: a 30 ms sleep holds nothing).
        let idle = await longestStall { try? await Task.sleep(for: .milliseconds(30)) }
        let fine = await longestStall { _ = await actions.dismiss(target, "d0") }
        let adopt = await longestStall { _ = await actions.adopt(target, target.glossaryProposals[0].identity) }
        let status = await longestStall {
            _ = await Task.detached { rounds.latestFinishedAndTrendsByPiece(language: "es") }.value
        }
        let centre = await longestStall {
            _ = await Task.detached { rounds.record(language: "es", docId: book.ids[0], number: 1) }.value
        }
        await book.documentStore.close()
        return String(format: "%d chapters (ledger %.1f MB, heartbeat floor %.1f ms) — main actor held, before → after: "
                      + "Fine %.1f → %.1f ms; Adopt (incl. a ruling) – → %.1f ms; Status's re-read %.1f → %.1f ms "
                      + "(2 decodes → 1, off main); the centre's re-read %.1f → %.1f ms",
                      chapters, Double(size) / 1_000_000, idle, fineBefore, fine, adopt, statusBefore, status,
                      centreBefore, centre)
    }

    /// **Run Whole Book's figure** (shell p4 Task 7 fix round, I2): every
    /// chapter closed with one Spanish paragraph; the first read (off the
    /// main actor) and a second over the unchanged book (the cache's
    /// fingerprint check) — wall time and the longest main-actor hold.
    private func preflightProbe(chapters: Int) async throws -> String {
        let book = try await ResolvePresenceTests.book(in: temp.url, chapters: chapters,
                                                       noted: Set(0..<chapters))
        for id in book.ids {
            let state = try book.store.derivedCache.state(forDocId: id, in: book.url)
            let first = try XCTUnwrap(state.sequence.first)
            try await TranslationStore.append(
                TranslationRecord(paragraphId: first, language: "es", text: "Uno.",
                                  sourceHash: TranslationHash.hash(state.paragraphs[first] ?? ""),
                                  verbatim: false),
                forDocId: id, identity: LocalIdentities.current.translator, identities: .current,
                in: book.url)
        }
        let idle = await longestStall { try? await Task.sleep(for: .milliseconds(30)) }
        let clock = ContinuousClock()
        var firstWall = 0.0
        let first = await longestStall {
            let start = clock.now
            _ = await TranslationPreflight.editionBudget(documentIds: book.ids, language: "es",
                                                         store: book.store, documentStore: book.documentStore)
            firstWall = self.ms(clock.now - start)
        }
        var againWall = 0.0
        let again = await longestStall {
            let start = clock.now
            _ = await TranslationPreflight.editionBudget(documentIds: book.ids, language: "es",
                                                         store: book.store, documentStore: book.documentStore)
            againWall = self.ms(clock.now - start)
        }
        await book.documentStore.close()
        return String(format: "%d chapters (heartbeat floor %.1f ms) — first read: wall %.1f ms, longest main-actor "
                      + "hold %.1f ms; cached: wall %.1f ms, hold %.1f ms",
                      chapters, idle, firstWall, first, againWall, again)
    }

    /// The longest gap a 1 ms main-actor heartbeat sees while `work` runs —
    /// the most the main actor was held at once.
    private func longestStall(_ work: () async -> Void) async -> Double {
        final class Beat { var last = ContinuousClock.now; var worst = 0.0; var running = true }
        let beat = Beat()
        let clock = ContinuousClock()
        let ticker = Task { @MainActor in
            while beat.running {
                let now = clock.now
                beat.worst = max(beat.worst, self.ms(now - beat.last))
                beat.last = now
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        await Task.yield()
        await work()
        let now = clock.now
        beat.worst = max(beat.worst, ms(now - beat.last))
        beat.running = false
        await ticker.value
        return beat.worst
    }

    func test_whatTheEditionsStatusReadCostsABook() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MAUGHAM_PERF_FIXTURE"] == "1",
            "perf fixture: run with TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1")
        // Shell p4 Task 6 adds the edition's To resolve read to the same
        // probe (one skip, one fixture shape).
        let table = ["EDITION STATUS COST (every chapter closed, one note and one es paragraph each)",
                     try await probe(chapters: 30),
                     try await probe(chapters: 200),
                     "EDITION TO RESOLVE COST (every chapter closed, one unsettled es change each)",
                     try await toResolveProbe(chapters: 30),
                     try await toResolveProbe(chapters: 200),
                     "SELECTING AN EDITION (the list's read; questions from the walk vs the presence read)",
                     try await switchProbe(chapters: 30),
                     try await switchProbe(chapters: 200),
                     "RUN WHOLE BOOK'S FIGURE (one edition, off the main actor, cached)",
                     try await preflightProbe(chapters: 30),
                     try await preflightProbe(chapters: 200),
                     "ONE VERB (main actor)",
                     try await verbProbe(chapters: 30),
                     try await verbProbe(chapters: 200)].joined(separator: "\n")
        let attachment = XCTAttachment(string: table)
        attachment.name = "edition-status-cost.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("\n" + table)
    }
}

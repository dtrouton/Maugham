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

    func test_whatTheEditionsStatusReadCostsABook() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MAUGHAM_PERF_FIXTURE"] == "1",
            "perf fixture: run with TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1")
        let table = ["EDITION STATUS COST (every chapter closed, one note and one es paragraph each)",
                     try await probe(chapters: 30),
                     try await probe(chapters: 200)].joined(separator: "\n")
        let attachment = XCTAttachment(string: table)
        attachment.name = "edition-status-cost.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("\n" + table)
    }
}

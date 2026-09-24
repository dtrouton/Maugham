import XCTest
@testable import Maugham
@testable import MaughamCore

/// **What a queue pays for its posture after a trust change** (signed op log
/// P3c plan 1, Task 10; Task 2's deferred minor m1).
///
/// `DocumentStore.posture(forDocId:)` is O(1) in a view body only after the
/// first question per document per epoch. A trust change clears the cache, so
/// the first redraw of a queue after one asks the builder once for every
/// distinct document it shows — each miss taking the registry signature to
/// know the table is still warm, and the document's class off the manifest.
/// This prices that pass on the main actor, for a queue of `rowCounts` rows
/// each on a document of its own (the worst case: a real queue repeats
/// documents, and a repeat is a hit).
///
/// Four passes per cycle, each timed over the whole queue:
/// - **during** — asked right after `invalidateTrust`, before the refresh
///   lands: the provisional answer (last known, never cached);
/// - **first after** — asked right after the refresh lands: the pass m1 is
///   about. Before ruling AD every row was a miss (42 ms at 50 rows); since,
///   the refresh warms every key the window has asked about before its epoch
///   bump, so this is a pass of hits;
/// - **hits** — the same queue again: the control;
/// - **unasked misses** — a queue of documents the window has never asked
///   about, with the table warm: the miss path itself.
///
/// **Env-gated and kept**, `NarrowedBookCostTests`' rule and for its reason. It
/// asserts nothing about a duration; it prints and attaches. Run it with:
///
///     TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1 xcodebuild -project Maugham.xcodeproj \
///       -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
///       -only-testing:MaughamTests/PostureMissCostTests
///
/// The book is the ROOT's, with one person narrowed to a piece — so the root
/// yields on that piece and the yield lookup is part of every answer.
@MainActor
final class PostureMissCostTests: XCTestCase {

    private static let rowCounts = [10, 50, 200]
    private static let cycles = 7

    private var temp: TempDirectory!

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        PieceWriterFixture.reset()
        temp.cleanup()
        temp = nil
    }

    func test_whatAQueuePaysForItsPostureAfterATrustChange() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MAUGHAM_PERF_FIXTURE"] == "1",
            "perf fixture: run with TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1")

        let book = try await PieceWriterFixture.narrowed(
            named: "posture-cost", in: temp.url, scopedTo: { [$0.pieceIDs[0]] })
        defer { PieceWriterFixture.reset() }

        let most = Self.rowCounts.max() ?? 0
        var ids = book.pieceIDs
        while ids.count < most {
            let item = try await book.store.addStructureItem(
                parentId: nil, title: "Row \(ids.count)", kind: .document(extension: "md"))
            ids.append(item.id)
        }
        let documentStore = book.documentStore
        // The production wiring (`ProjectWindow` sets it): the door reads the
        // window's live manifest rather than the file.
        documentStore.projectStore = book.store
        documentStore.invalidateTrust()
        await documentStore.postureSettled()

        var table = "=== P3c Task 10 \u{2014} posture(forDocId:) across a trust "
            + "change (medians of \(Self.cycles), ms per whole queue; "
            + "one document per row) ===\n"
        table += "rows".padding(toLength: 8, withPad: " ", startingAt: 0)
            + ["during refresh", "first after", "hits", "unasked misses", "per miss"]
                .map { $0.padding(toLength: 18, withPad: " ", startingAt: 0) }
                .joined() + "\n"

        for rows in Self.rowCounts {
            let queue = Array(ids.prefix(rows))
            // Every row asked once, so each has a last-known answer — the
            // state a queue that has been on screen is in.
            for id in queue { _ = documentStore.posture(forDocId: id) }

            var during: [Double] = [], after: [Double] = [], hits: [Double] = []
            var misses: [Double] = []
            for cycle in 0..<Self.cycles {
                documentStore.invalidateTrust()
                during.append(time { for id in queue { _ = documentStore.posture(forDocId: id) } })
                await documentStore.postureSettled()
                after.append(time { for id in queue { _ = documentStore.posture(forDocId: id) } })
                hits.append(time { for id in queue { _ = documentStore.posture(forDocId: id) } })
                // A queue of documents this window has never asked about: the
                // miss path itself, with the table warm. An id the manifest
                // does not hold is a piece, and costs the builder exactly
                // what a real one does.
                let unasked = (0..<rows).map { "unasked-\(rows)-\(cycle)-\($0)" }
                misses.append(time { for id in unasked { _ = documentStore.posture(forDocId: id) } })
            }
            let unasked = median(misses)
            table += "\(rows)".padding(toLength: 8, withPad: " ", startingAt: 0)
                + [median(during), median(after), median(hits), unasked, unasked / Double(rows)]
                    .map { String(format: "%.3f", $0)
                        .padding(toLength: 18, withPad: " ", startingAt: 0) }
                    .joined() + "\n"
        }

        // **Where a miss goes.** What a miss does that a hit does
        // not, each asked once per row of the largest queue on its own: the
        // is-there-a-register question (the drawing accessor asks it on every
        // miss, the provisional ones included), the folder signature (asked
        // once the table is warm), and the document's class off the manifest
        // (the builder's closure).
        let queue = Array(ids.prefix(most))
        let url = book.url
        let cache = Document.loadRegistryCache
        // Each part timed as `most` calls of itself, per call.
        let perRow: [(String, () -> Void)] = [
            ("hasAnythingToResolve", { _ = TrustResolution.hasAnythingToResolve(in: url, cache: cache) }),
            ("signature(of:)", { _ = TrustResolution.signature(of: url) }),
        ]
        table += "\nper row, x\(most) (medians of \(Self.cycles), ms per call):\n"
        func row(_ name: String, _ samples: [Double]) {
            table += name.padding(toLength: 24, withPad: " ", startingAt: 0)
                + String(format: "%.3f", median(samples)) + "\n"
        }
        for (name, call) in perRow {
            row(name, (0..<Self.cycles).map { _ in
                time { for _ in 0..<most { call() } } / Double(most)
            })
        }
        // The class: one call per document in the queue.
        row("documentClass", (0..<Self.cycles).map { _ in
            time { for id in queue { _ = Document.documentClass(forDocId: id, in: url) } }
                / Double(most)
        })

        let attachment = XCTAttachment(string: table)
        attachment.name = "posture-miss-cost.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("\n" + table)
    }

    private func time(_ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        body()
        let elapsed = clock.now - start
        return Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
    }

    private func median(_ samples: [Double]) -> Double {
        samples.sorted()[samples.count / 2]
    }
}

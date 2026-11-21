import XCTest
import MaughamCore
@testable import Maugham

/// **What the tree's "something to resolve" read costs a book** (shell p4
/// Task 3, fix rounds 1 and 2; the review's I2 and the owner's bar that
/// opening a book must not hitch).
///
/// The presence read runs in every window whether or not To resolve is
/// visible. This probe measures it on a 200-chapter book whose every chapter
/// is closed and holds one open note — so a walk re-derives all 200 — and
/// records, for each read, the LONGEST single main-actor step as well as the
/// main-actor total and the wall time:
///
/// - **before** (fix round 1): the store's synchronous walk on the main
///   actor, gathered and marked, for the first read and for a burst's one
///   coalesced walk;
/// - **after** (fix round 2): `ResolvePresenceReader.update`, then its walk
///   off the main actor (`ResolveChunkedWalk`), each chunk one main-actor
///   step; plus a chapter opening and closing, which walks nothing.
///
/// The after half runs on its own `ProjectStore` and `DocumentStore`, so it
/// reads through no cache the before half warmed. Only the read is timed:
/// opening a `Document` and writing the notes are the writer's and the
/// round's.
///
/// **Env-gated and kept**, `NarrowedBookCostTests`' rule: it is heavy, it is
/// a measurement, and nothing is asserted about a duration. Run it with:
///
///     TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1 xcodebuild -project Maugham.xcodeproj \
///       -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
///       -only-testing:MaughamTests/ResolvePresenceCostTests
@MainActor
final class ResolvePresenceCostTests: XCTestCase {

    private static let chapters = 200
    private static let navigations = 7
    private static let burst = 20

    private var temp: TempDirectory!

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        temp.cleanup()
        temp = nil
    }

    private func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// One read's main-actor cost: its longest single step, the sum of its
    /// steps, and the wall time to the last mark.
    private struct Cost {
        var longest = 0.0
        var mainTotal = 0.0
        var wall = 0.0
        var steps = 0
        /// From asking for the walk to its first step (the trust resolve).
        var firstStep: Double?

        mutating func add(_ step: Double) {
            longest = max(longest, step)
            mainTotal += step
            steps += 1
        }

        var text: String {
            String(format: "longest step %.1f ms, main-actor total %.1f ms over %d steps, wall %.1f ms%@",
                   longest, mainTotal, steps, wall,
                   firstStep.map { String(format: " (first step after %.1f ms)", $0) } ?? "")
        }
    }

    /// **Before (fix round 1)**: the store's synchronous walk on the main
    /// actor, gathered and marked — one step.
    private func oneShot(store: ProjectStore, documentStore: DocumentStore) -> Cost {
        let clock = ContinuousClock()
        var cost = Cost()
        let elapsed = ms(clock.measure {
            let manifest = store.manifest
            let read = ResolveReader.read(
                scope: ResolveScope.of(.project, structure: manifest.structure, projectType: manifest.type),
                store: store, documentStore: documentStore, diagnostics: nil)
            let owners = ProjectStore.figureNoteOwners(manifest.figures ?? [])
            _ = ResolvePresence.marks(read, structure: manifest.structure, figureOwners: owners, sceneIndex: nil)
            _ = ResolvePresence.openToDos(read.items, figureOwners: owners)
        })
        cost.add(elapsed)
        cost.wall = elapsed
        return cost
    }

    /// **After**: the reader's `update`, then its walk — each step timed as
    /// the main actor pays it (`ResolvePresenceReader.run`'s loop).
    private func chunked(_ reader: ResolvePresenceReader, token: Int, store: ProjectStore,
                         documentStore: DocumentStore) async -> Cost {
        let clock = ContinuousClock()
        var cost = Cost()
        let start = clock.now
        for _ in 0..<4 {
            let key = ResolvePresenceReader.key(store: store, documentStore: documentStore,
                                                diagnostics: nil, annotationsToken: token, script: nil)
            cost.add(ms(clock.measure {
                reader.update(key, store: store, documentStore: documentStore, diagnostics: nil)
            }))
            while let request = reader.pendingRequest {
                let inputs = ResolveChunkedWalk.inputs(for: request, store: store)
                let asked = clock.now
                for await step in ResolveChunkedWalk.steps(inputs) {
                    if cost.firstStep == nil { cost.firstStep = ms(clock.now - asked) }
                    cost.add(ms(clock.measure {
                        reader.apply(step, generation: request.generation, store: store,
                                     documentStore: documentStore, diagnostics: nil)
                    }))
                    await Task.yield()
                }
                reader.finish(generation: request.generation)
            }
            if key == ResolvePresenceReader.key(store: store, documentStore: documentStore,
                                                diagnostics: nil, annotationsToken: token,
                                                script: nil) { break }
        }
        cost.wall = ms(clock.now - start)
        return cost
    }

    func test_whatThePresenceReadCostsABook() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MAUGHAM_PERF_FIXTURE"] == "1",
            "perf fixture: run with TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1")
        let book = try await ResolvePresenceTests.book(
            in: temp.url, chapters: Self.chapters, noted: Set(0..<Self.chapters))

        // Before: the first read, and a burst's one coalesced walk.
        let beforeFirst = oneShot(store: book.store, documentStore: book.documentStore)
        for index in 0..<Self.burst {
            try await ResolvePresenceTests.addNote(to: book.ids[100 + index], in: book.url,
                                                   body: "round note \(100 + index)")
        }
        let beforeBurst = oneShot(store: book.store, documentStore: book.documentStore)
        await book.documentStore.close()

        // After, on its own stores (no cache shared with the run above).
        let store = try await ProjectStore.load(from: book.url)
        let documentStore = try await DocumentStore.open(url: book.url)
        store.documentStore = documentStore
        documentStore.projectStore = store
        let reader = ResolvePresenceReader()
        var token = 0
        let afterFirst = await chunked(reader, token: token, store: store, documentStore: documentStore)
        let tokensAfterFirst = DerivedManuscriptCache.tokens(forDocIds: book.ids, in: book.url)
        let trustAfterFirst = try? TrustResolution.resolve(projectURL: book.url, identities: .current)

        var opens = Cost(), closes = Cost()
        let walks = reader.walksRequested
        for step in 0..<Self.navigations {
            let rel = "manuscript/\(book.ids[step * 11]).md"
            let doc = try await Document.load(url: book.url.appendingPathComponent(rel), actor: .author,
                                              session: "nav", presenter: nil)
            documentStore.register(document: doc, for: rel)
            let open = await chunked(reader, token: token, store: store, documentStore: documentStore)
            opens.add(open.longest)
            documentStore.unregister(path: rel)
            await doc.close()
            let close = await chunked(reader, token: token, store: store, documentStore: documentStore)
            closes.add(close.longest)
        }
        let navigationWalks = reader.walksRequested - walks

        for index in 0..<Self.burst {
            try await ResolvePresenceTests.addNote(to: book.ids[150 + index], in: book.url,
                                                   body: "round note \(150 + index)")
        }
        token += 1
        let tokensBeforeBurst = DerivedManuscriptCache.tokens(forDocIds: book.ids, in: book.url)
        let moved = book.ids.filter { tokensAfterFirst[$0] != tokensBeforeBurst[$0] }.count
        let trustMoved = trustAfterFirst != (try? TrustResolution.resolve(projectURL: book.url, identities: .current))
        let readBeforeBurst = reader.piecesRead
        let afterBurst = await chunked(reader, token: token, store: store, documentStore: documentStore)
        let burstReads = reader.piecesRead - readBeforeBurst

        // A token move with nothing changed: every piece is checked, none read.
        token += 1
        let readBeforeQuiet = reader.piecesRead
        let walksBeforeQuiet = reader.walksRequested
        let afterQuiet = await chunked(reader, token: token, store: store, documentStore: documentStore)
        let quietReads = reader.piecesRead - readBeforeQuiet
        // The producer alone, synchronously, on a quiet book: where its time goes.
        var syncQuiet = ""
        do {
            let request = ResolveChunkedWalk.Request(
                generation: -1, docIds: book.ids, readsFigures: true,
                known: DerivedManuscriptCache.tokens(forDocIds: book.ids, in: book.url),
                knownTrust: try? TrustResolution.resolve(projectURL: book.url, identities: .current),
                knownFacts: DocumentClass.Facts(store.manifest))
            var walker = ResolveChunkedWalk.Walker(ResolveChunkedWalk.inputs(for: request, store: store))
            let clock = ContinuousClock()
            var times: [Double] = []
            var unchanged = 0
            while true {
                var step: ResolveChunkedWalk.Step?
                times.append(ms(clock.measure { step = walker.next() }))
                guard let step else { break }
                if case .pieces(let reads) = step {
                    unchanged += reads.filter { if case .unchanged = $0 { return true } else { return false } }.count
                }
            }
            syncQuiet = String(format: "producer alone, quiet: trust %.1f ms, chunks %.1f ms in all, %d unchanged",
                               times.first ?? 0, times.dropFirst().reduce(0, +), unchanged)
        }
        await documentStore.close()

        let table = [
            "PRESENCE COST (\(Self.chapters) closed chapters, each with one open note; chunk \(ResolveChunkedWalk.chunkSize))",
            "before (one synchronous walk on the main actor) — first read: " + beforeFirst.text,
            "before — a burst of \(Self.burst) closed-chapter notes, one walk: " + beforeBurst.text,
            "after (chunked, off the main actor) — first read: " + afterFirst.text,
            "after — a burst of \(Self.burst) closed-chapter notes, one walk: " + afterBurst.text
                + " (\(burstReads) pieces read; \(moved) pieces' files had moved since the first read; trust moved: \(trustMoved))",
            "after — a token move with nothing changed: " + afterQuiet.text + " (\(quietReads) pieces read, \(reader.walksRequested - walksBeforeQuiet) walks)",
            syncQuiet,
            String(format: "after — open a chapter: longest step %.2f ms (worst of %d); close one: %.2f ms; %d walks",
                   opens.longest, Self.navigations, closes.longest, navigationWalks),
        ].joined(separator: "\n")
        // Kept in the result bundle (`NarrowedBookCostTests`' reason). Pull it with:
        //
        //   xcrun xcresulttool export attachments \
        //     --path <bundle>.xcresult --output-path <dir>
        let attachment = XCTAttachment(string: table)
        attachment.name = "resolve-presence-cost.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("\n" + table)
        XCTAssertEqual(navigationWalks, 0, "the reader walks nothing on navigation")
        XCTAssertEqual(reader.marks, oneShotMarks(store: store, documentStore: documentStore),
                       "the chunked read ends at the one-shot answer")
    }

    private func oneShotMarks(store: ProjectStore, documentStore: DocumentStore) -> ResolvePresence.Marks {
        let manifest = store.manifest
        let read = ResolveReader.read(
            scope: ResolveScope.of(.project, structure: manifest.structure, projectType: manifest.type),
            store: store, documentStore: documentStore, diagnostics: nil)
        return ResolvePresence.marks(read, structure: manifest.structure,
                                     figureOwners: ProjectStore.figureNoteOwners(manifest.figures ?? []),
                                     sceneIndex: nil)
    }
}

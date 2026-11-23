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
                scope: ResolveScope.of(.project, readIn: nil, sourceLanguage: "en", structure: manifest.structure, projectType: manifest.type),
                store: store, documentStore: documentStore, diagnostics: nil, figureChanges: [])
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
                                                diagnostics: nil, annotationsToken: token, script: nil, figureChanges: [])
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
                                                script: nil, figureChanges: []) { break }
        }
        cost.wall = ms(clock.now - start)
        return cost
    }

    func test_whatThePresenceReadCostsABook() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MAUGHAM_PERF_FIXTURE"] == "1",
            "perf fixture: run with TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1")
        // A changed figure (shell p5 Task 3, fix round 1), on its own book.
        try await measureAChangedFigure()
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

    /// **What a changed figure costs a 200-chapter book** (shell p5 Task 3,
    /// fix round 1, I2): one chapter open, a changed table placed in it.
    /// Typing above the figure moves its line: the presence read and a Book
    /// list beside the chapter should do nothing; the chapter's own list
    /// re-reads its one piece. A card fill (a figure's source changing)
    /// re-gathers the presence and re-reads the Book over its held walks.
    /// Each row is the median and the worst of `navigations` runs, main actor.
    /// Run inside `test_whatThePresenceReadCostsABook`, behind its one gate
    /// (the skip baseline counts one skipped probe, not two).
    private func measureAChangedFigure() async throws {
        let book = try await ResolvePresenceTests.book(
            in: temp.url, chapters: Self.chapters, noted: Set(0..<Self.chapters))
        let store = book.store, documentStore = book.documentStore
        let chapter = book.ids[2]
        let rel = "manuscript/\(chapter).md"
        let doc = try await Document.load(url: book.url.appendingPathComponent(rel), actor: .author,
                                          session: "fig", presenter: nil)
        documentStore.register(document: doc, for: rel)
        func change(_ id: String, line: Int, in docId: String) -> ResolveFigureChange {
            ResolveFigureChange(figureId: id, number: "Table 1", title: "cash", pinsChanged: true,
                                placements: [FigureListing.Use(docId: docId, lineIndex: line)])
        }
        let clock = ContinuousClock()
        func presenceKey(_ changes: [ResolveFigureChange]) -> ResolvePresenceReader.Key {
            ResolvePresenceReader.key(store: store, documentStore: documentStore, diagnostics: nil,
                                      annotationsToken: 0, script: nil, figureChanges: changes)
        }
        // The presence read, settled over the whole book first.
        let reader = ResolvePresenceReader()
        reader.update(presenceKey([change("fig-00000001", line: 0, in: chapter)]),
                      store: store, documentStore: documentStore, diagnostics: nil)
        while let request = reader.pendingRequest {
            await reader.run(request, store: store, documentStore: documentStore, diagnostics: nil)
        }
        let bookScope = ResolveScope.of(.project, readIn: nil, sourceLanguage: "en",
                                        structure: store.manifest.structure, projectType: .novel)
        let pieceScope = ResolveScope.piece(docId: chapter, includesBookLevel: false)
        // One list per scope, each holding its own walks, as each pane does.
        var bookWalks = ResolveWalkHold(), pieceWalks = ResolveWalkHold()
        func listKey(_ scope: ResolveScope, _ changes: [ResolveFigureChange]) -> ResolveListKey {
            ResolvePane.listKey(scope: scope, annotationsToken: 0, store: store, documentStore: documentStore,
                                diagnostics: nil, localName: "", script: nil, figureChanges: changes)
        }
        func refresh(_ scope: ResolveScope, from: [ResolveFigureChange], to: [ResolveFigureChange],
                     held: inout ResolveSnapshot, walks: inout ResolveWalkHold) -> (ResolveRefreshStep, Double) {
            let last = listKey(scope, from), next = listKey(scope, to)
            let step = ResolvePane.refreshStep(next, last: last)
            var out = held
            let before = held
            var hold = walks
            let elapsed = ms(clock.measure {
                out = ResolvePane.refreshed(before, step: step, key: next.regroup.read, walks: &hold,
                                            store: store, documentStore: documentStore, diagnostics: nil)
            })
            walks = hold
            held = out
            return (step, elapsed)
        }
        let projectTasksAtFirst = store.projectTasksVersion
        var bookHeld = ResolvePane.refreshed(.empty, step: .read, key: listKey(bookScope, []).regroup.read,
                                             walks: &bookWalks, store: store, documentStore: documentStore,
                                             diagnostics: nil)
        var pieceHeld = ResolvePane.refreshed(.empty, step: .read, key: listKey(pieceScope, []).regroup.read,
                                              walks: &pieceWalks, store: store, documentStore: documentStore,
                                              diagnostics: nil)
        // The first read in a store's life also loads the project's own log
        // (ADR 0036's accepted one-off): its version moves after the first
        // read, so the next re-walks the tasks once. Settle that first, so
        // the rows below time the figures alone; the one-off is reported.
        let projectTasksBefore = store.projectTasksVersion
        let warm = ms(clock.measure {
            bookHeld = ResolvePane.refreshed(bookHeld, step: .read, key: listKey(bookScope, []).regroup.read,
                                             walks: &bookWalks, store: store, documentStore: documentStore,
                                             diagnostics: nil)
        })
        let warmMoved = projectTasksBefore != store.projectTasksVersion
        let firstMoved = projectTasksAtFirst != projectTasksBefore
        var rows: [String: [Double]] = [:]
        var steps: [String: ResolveRefreshStep] = [:]
        for run in 0..<Self.navigations {
            let from = [change("fig-00000001", line: run, in: chapter)]
            let moved = [change("fig-00000001", line: run + 1, in: chapter)]
            let filled = moved + [change(String(format: "fig-%08x", 0x100 + run), line: 0, in: book.ids[150])]
            rows["presence, line move", default: []].append(ms(clock.measure {
                reader.update(presenceKey(moved), store: store, documentStore: documentStore, diagnostics: nil)
            }))
            rows["presence, card fill", default: []].append(ms(clock.measure {
                reader.update(presenceKey(filled), store: store, documentStore: documentStore, diagnostics: nil)
            }))
            reader.update(presenceKey(from), store: store, documentStore: documentStore, diagnostics: nil)
            var (step, elapsed) = refresh(bookScope, from: from, to: moved, held: &bookHeld, walks: &bookWalks)
            steps["Book list, line move"] = step; rows["Book list, line move", default: []].append(elapsed)
            (step, elapsed) = refresh(bookScope, from: moved, to: filled, held: &bookHeld, walks: &bookWalks)
            steps["Book list, card fill"] = step; rows["Book list, card fill", default: []].append(elapsed)
            (step, elapsed) = refresh(pieceScope, from: from, to: moved, held: &pieceHeld, walks: &pieceWalks)
            steps["chapter's own list, line move"] = step
            rows["chapter's own list, line move", default: []].append(elapsed)
        }
        documentStore.unregister(path: rel)
        await doc.close()
        await documentStore.close()
        let order = ["presence, line move", "presence, card fill", "Book list, line move",
                     "Book list, card fill", "chapter's own list, line move"]
        let table = (["CHANGED FIGURE COST (\(Self.chapters) chapters, one open, each with one open note; no strains)",
                      String(format: "first Book re-read in the store's life (no figure): %.1f ms", warm)
                        + " (project tasks version moved during the first read: \(firstMoved); during this one: \(warmMoved))"]
            + order.map { name in
                String(format: "%@: median %.2f ms, worst %.2f ms%@ [%@]", name, median(rows[name] ?? [0]),
                       (rows[name] ?? [0]).max() ?? 0, steps[name].map { " (step \($0))" } ?? "",
                       (rows[name] ?? []).map { String(format: "%.1f", $0) }.joined(separator: " "))
            }).joined(separator: "\n")
        let attachment = XCTAttachment(string: table)
        attachment.name = "changed-figure-cost.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("\n" + table)
        XCTAssertEqual(steps["Book list, line move"], .live)
    }

    private func oneShotMarks(store: ProjectStore, documentStore: DocumentStore) -> ResolvePresence.Marks {
        let manifest = store.manifest
        let read = ResolveReader.read(
            scope: ResolveScope.of(.project, readIn: nil, sourceLanguage: "en", structure: manifest.structure, projectType: manifest.type),
            store: store, documentStore: documentStore, diagnostics: nil, figureChanges: [])
        return ResolvePresence.marks(read, structure: manifest.structure,
                                     figureOwners: ProjectStore.figureNoteOwners(manifest.figures ?? []),
                                     sceneIndex: nil)
    }
}

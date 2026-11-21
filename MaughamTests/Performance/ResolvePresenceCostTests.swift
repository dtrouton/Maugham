import XCTest
import MaughamCore
@testable import Maugham

/// **What the tree's "something to resolve" read costs a book** (shell p4
/// Task 3, fix round 1; the review's I2).
///
/// The presence read runs in every window whether or not To resolve is
/// visible, so its cost is the writer's on every chapter they move to. This
/// probe measures it on a 200-chapter book whose every chapter is closed and
/// holds one open note — so a walk that misses the store's cache re-derives
/// all 200 — two ways, on one machine in one run:
///
/// - **before**: the watch as Task 3 first built it — To resolve's own
///   refresh at the Book's scope (`ResolvePane.listKey` → `refreshStep` →
///   `refreshed`), whose walk key holds the open pieces, with one token move
///   per closed-piece event;
/// - **after**: `ResolvePresenceReader`, which never walks on a piece opening
///   or closing and whose watch coalesces a burst of events into one token
///   move.
///
/// Each path has its own `ProjectStore` and `DocumentStore` over the same
/// project, so neither reads through the other's cache. Each navigation
/// figure is the median of seven; the burst is twenty notes landing in twenty
/// closed chapters. Only the refresh is timed: opening the `Document`, and
/// writing the notes, are the writer's and the round's, not the read's.
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

    /// One way of keeping the presence current: refresh, then say how many
    /// annotation walks ran.
    @MainActor private protocol Path: AnyObject {
        var token: Int { get set }
        @MainActor func refresh()
    }

    /// Task 3 as first built: To resolve's refresh at the Book's scope.
    @MainActor private final class Before: Path {
        let store: ProjectStore
        let documentStore: DocumentStore
        var token = 0
        var held: ResolveSnapshot = .empty
        var last: ResolveListKey?
        var walks = ResolveWalkHold()

        init(store: ProjectStore, documentStore: DocumentStore) {
            self.store = store
            self.documentStore = documentStore
        }

        @MainActor func refresh() {
            for _ in 0..<3 {
                let scope = ResolveScope.of(.project, structure: store.manifest.structure,
                                            projectType: store.manifest.type)
                let key = ResolvePane.listKey(scope: scope, annotationsToken: token, store: store,
                                              documentStore: documentStore, diagnostics: nil,
                                              localName: "", script: nil)
                guard key != last else { return }
                let step = ResolvePane.refreshStep(key, last: last)
                held = ResolvePane.refreshed(held, step: step, key: key.regroup.read, walks: &walks,
                                             store: store, documentStore: documentStore, diagnostics: nil)
                last = key
                let owners = ProjectStore.figureNoteOwners(store.manifest.figures ?? [])
                _ = ResolvePresence.marks(held, structure: store.manifest.structure,
                                          figureOwners: owners, sceneIndex: nil)
                _ = ResolvePresence.openToDos(held.items, figureOwners: owners)
            }
        }
    }

    /// The reader, as its watch drives it.
    @MainActor private final class After: Path {
        let store: ProjectStore
        let documentStore: DocumentStore
        let reader = ResolvePresenceReader()
        var token = 0

        init(store: ProjectStore, documentStore: DocumentStore) {
            self.store = store
            self.documentStore = documentStore
        }

        @MainActor func refresh() {
            for _ in 0..<3 {
                let key = ResolvePresenceReader.key(store: store, documentStore: documentStore,
                                                    diagnostics: nil, annotationsToken: token, script: nil)
                reader.update(key, store: store, documentStore: documentStore, diagnostics: nil)
                if key == ResolvePresenceReader.key(store: store, documentStore: documentStore,
                                                    diagnostics: nil, annotationsToken: token,
                                                    script: nil) { return }
            }
        }
    }

    private func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private struct Measured {
        var first = 0.0
        var opens: [Double] = []
        var closes: [Double] = []
        var burst = 0.0
        var walks = (navigation: 0, burst: 0)
    }

    private func measure(_ path: Path, store: ProjectStore, documentStore: DocumentStore,
                         url: URL, ids: [String], burstFrom: Int, batched: Bool) async throws -> Measured {
        let clock = ContinuousClock()
        var measured = Measured()
        measured.first = ms(clock.measure { path.refresh() })

        let before = store._debugAnnotationsRebuildCount
        for step in 0..<Self.navigations {
            let id = ids[step * 11]
            let rel = "manuscript/\(id).md"
            let doc = try await Document.load(url: url.appendingPathComponent(rel), actor: .author,
                                              session: "nav", presenter: nil)
            documentStore.register(document: doc, for: rel)
            measured.opens.append(ms(clock.measure { path.refresh() }))
            documentStore.unregister(path: rel)
            await doc.close()
            measured.closes.append(ms(clock.measure { path.refresh() }))
        }
        measured.walks.navigation = store._debugAnnotationsRebuildCount - before

        let beforeBurst = store._debugAnnotationsRebuildCount
        var total = 0.0
        for index in 0..<Self.burst {
            try await ResolvePresenceTests.addNote(to: ids[burstFrom + index], in: url,
                                                   body: "round note \(burstFrom + index)")
            if !batched {
                path.token += 1
                total += ms(clock.measure { path.refresh() })
            }
        }
        if batched {
            path.token += 1
            total += ms(clock.measure { path.refresh() })
        }
        measured.burst = total
        measured.walks.burst = store._debugAnnotationsRebuildCount - beforeBurst
        return measured
    }

    func test_whatThePresenceReadCostsABook() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MAUGHAM_PERF_FIXTURE"] == "1",
            "perf fixture: run with TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1")
        let book = try await ResolvePresenceTests.book(
            in: temp.url, chapters: Self.chapters, noted: Set(0..<Self.chapters))

        let beforeDS = book.documentStore
        let old = try await measure(Before(store: book.store, documentStore: beforeDS),
                                    store: book.store, documentStore: beforeDS, url: book.url,
                                    ids: book.ids, burstFrom: 100, batched: false)

        let store = try await ProjectStore.load(from: book.url)
        let documentStore = try await DocumentStore.open(url: book.url)
        store.documentStore = documentStore
        documentStore.projectStore = store
        let new = try await measure(After(store: store, documentStore: documentStore),
                                    store: store, documentStore: documentStore, url: book.url,
                                    ids: book.ids, burstFrom: 150, batched: true)
        await documentStore.close()
        await beforeDS.close()

        func line(_ name: String, _ m: Measured) -> String {
            String(format: "%@: first read %.1f ms; open a chapter %.2f ms, close one %.2f ms (medians of %d; %d walks); burst of %d closed-chapter notes %.1f ms (%d walks)",
                   name, m.first, median(m.opens), median(m.closes), Self.navigations,
                   m.walks.navigation, Self.burst, m.burst, m.walks.burst)
        }
        let table = ["PRESENCE COST (\(Self.chapters) closed chapters, each with one open note)",
                     line("before", old), line("after", new)].joined(separator: "\n")
        // Kept in the result bundle (`NarrowedBookCostTests`' reason). Pull it with:
        //
        //   xcrun xcresulttool export attachments \
        //     --path <bundle>.xcresult --output-path <dir>
        let attachment = XCTAttachment(string: table)
        attachment.name = "resolve-presence-cost.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("\n" + table)
        XCTAssertEqual(new.walks.navigation, 0, "the reader walks nothing on navigation")
        XCTAssertEqual(new.walks.burst, 1, "a coalesced burst is one walk")
    }
}

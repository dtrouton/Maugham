import XCTest
@testable import Maugham
@testable import MaughamCore

/// **The window's figure cards** (report plan 7a Task 3): filled off the
/// typing path, read from memory only, one fill per burst of triggers, and
/// nothing landing once the host has gone.
@MainActor
final class FigureCardCacheTests: XCTestCase {

    // MARK: - A source the test controls

    /// Counts every read (the cache's only I/O) and can hold the next one until released.
    private final class FakeSource {
        var inputs: FigureCardInputs
        private(set) var reads = 0
        var holding = false
        private var held: CheckedContinuation<Void, Never>?

        init(_ inputs: FigureCardInputs) { self.inputs = inputs }

        var source: FigureCardCache.Source {
            FigureCardCache.Source(read: { [self] in
                reads += 1
                // Holds one read only: a second read beside it answers at once.
                if holding { holding = false; await withCheckedContinuation { held = $0 } }
                return inputs
            })
        }

        var isHolding: Bool { held != nil }

        func release() {
            holding = false
            held?.resume()
            held = nil
        }
    }

    private static let en = TableLocale(languageTag: "en-GB", fallbackRegion: "GB")

    private func record(_ id: String, _ name: String, kind: FigureKind = .table) -> FigureRecord {
        FigureRecord(id: id, name: name, kind: kind, piece: nil,
                     path: kind == .table ? "figures/\(name).csv" : "figures/\(name).png")
    }

    private func table(_ values: [Double]) -> FigureState {
        var t = FigureTable(rows: values.count, columns: 1)
        for (i, v) in values.enumerated() {
            t.setCell(Cell(content: .value(.number(v))), at: CellKey(row: t.rows[i], column: t.columns[0]))
        }
        return FigureState(kind: .table, table: t)
    }

    private func inputs(_ figures: [(FigureRecord, FigureState)]) -> FigureCardInputs {
        var book = Workbook(pins: FigurePinIndex())
        for (r, s) in figures where s.kind == .table { book.setTable(s.table, id: r.id) }
        return FigureCardInputs(
            records: figures.map(\.0),
            states: Dictionary(figures.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a }),
            workbook: book, pinChanged: [], locale: Self.en)
    }

    // MARK: - Coalescing

    /// **Several triggers in one turn make one fill and one version bump**,
    /// and a fill that changes nothing does not bump.
    func test_severalTriggersInOneTurnMakeOneFillAndOneBump() async {
        let cash = record("fig-0a1b2c3d", "cash"), debt = record("fig-1a1b2c3d", "debt")
        let fake = FakeSource(inputs([(cash, table([1])), (debt, table([2]))]))
        let cache = FigureCardCache()
        var bumps: [Int] = []
        cache.onVersionChange = { bumps.append($0) }
        cache.attach(fake.source)
        await cache.idle()
        XCTAssertEqual(fake.reads, 1)
        XCTAssertEqual(cache.version, 1, "the first fill bumps")
        XCTAssertEqual(cache.model(forFigureId: cash.id)?.bodyRows, [["1"]])

        fake.inputs = inputs([(cash, table([10])), (debt, table([20, 30]))])
        cache.invalidate()
        cache.invalidate()
        cache.invalidate()
        await cache.idle()
        XCTAssertEqual(fake.reads, 2, "three triggers in one turn: one fill")
        XCTAssertEqual(cache.version, 2, "and one bump")
        XCTAssertEqual(bumps, [1, 2])
        XCTAssertEqual(cache.model(forFigureId: debt.id)?.bodyRows, [["20"], ["30"]])

        cache.invalidate()
        await cache.idle()
        XCTAssertEqual(fake.reads, 3)
        XCTAssertEqual(cache.version, 2, "a fill that changes nothing does not bump")
    }

    /// **A trigger during a fill makes one more fill after it**, never a
    /// second fill beside it whose older answer could land last.
    func test_aTriggerDuringAFillRefillsAfterIt_andTheNewestAnswerStands() async {
        let cash = record("fig-0a1b2c3d", "cash")
        let fake = FakeSource(inputs([(cash, table([1]))]))
        fake.holding = true
        let cache = FigureCardCache()
        cache.attach(fake.source)
        while !fake.isHolding { await Task.yield() }

        fake.inputs = inputs([(cash, table([2]))])
        cache.invalidate()
        await Task.yield()
        XCTAssertEqual(fake.reads, 1, "no second read while the first is in flight")
        fake.release()
        await cache.idle()
        XCTAssertEqual(fake.reads, 2, "one more fill after it")
        XCTAssertEqual(cache.model(forFigureId: cash.id)?.bodyRows, [["2"]], "the newest answer stands")
    }

    // MARK: - Reads are memory only

    /// **A miss answers nil and reads nothing**: before the first fill, and
    /// for a figure the fill did not build.
    func test_aMissAnswersNilWithoutARead() async {
        let cash = record("fig-0a1b2c3d", "cash")
        let fake = FakeSource(inputs([(cash, table([1]))]))
        let cache = FigureCardCache()
        cache.attach(fake.source)
        // Same turn: the fill has not run.
        XCTAssertNil(cache.model(forFigureId: cash.id))
        XCTAssertNil(cache.model(forLinePath: "../figures/cash.csv", documentPath: "manuscript/a.md"),
                     "before the first fill a line is a miss, not a removed figure")
        XCTAssertEqual(fake.reads, 0, "a lookup never reads")

        await cache.idle()
        XCTAssertEqual(fake.reads, 1)
        XCTAssertNil(cache.model(forFigureId: "fig-ffffffff"))
        for _ in 0..<50 { _ = cache.model(forLinePath: "../figures/cash.csv", documentPath: "manuscript/a.md") }
        XCTAssertEqual(fake.reads, 1, "lookups, hit or miss, never read")
        XCTAssertNotNil(cache.model(forFigureId: cash.id), "control: the filled figure is there")
    }

    // MARK: - Closing

    /// **A fill landing after the host has gone is dropped**: no card, no
    /// bump, no callback.
    func test_aFillLandingAfterCloseIsDropped() async {
        let cash = record("fig-0a1b2c3d", "cash")
        let fake = FakeSource(inputs([(cash, table([1]))]))
        fake.holding = true
        let cache = FigureCardCache()
        var bumps = 0
        cache.onVersionChange = { _ in bumps += 1 }
        cache.attach(fake.source)
        while !fake.isHolding { await Task.yield() }

        cache.attach(nil)
        fake.release()
        await cache.idle()
        XCTAssertNil(cache.model(forFigureId: cash.id), "the late fill built nothing")
        XCTAssertEqual(cache.version, 0)
        XCTAssertEqual(bumps, 0)
        cache.invalidate()
        await cache.idle()
        XCTAssertEqual(fake.reads, 1, "a detached cache does not fill again")
    }

    // MARK: - Broken cards (R7a-3)

    /// **A figure removed from the registry becomes `.removed`** under its
    /// line; two records on one path are `.ambiguous`; a parked figure is
    /// `.parked`; a line to a picture in Research is `.image`.
    func test_aRemovedFigureBecomesRemoved() async {
        let cash = record("fig-0a1b2c3d", "cash")
        let fake = FakeSource(inputs([(cash, table([1, 2]))]))
        let cache = FigureCardCache()
        cache.attach(fake.source)
        await cache.idle()
        let line = "../figures/cash.csv", doc = "manuscript/a.md"
        XCTAssertEqual(cache.model(forLinePath: line, documentPath: doc)?.kind, .table)
        XCTAssertEqual(cache.model(forLinePath: "../research/photo.png", documentPath: doc)?.kind, .image,
                       "a line outside figures/ is today's thumbnail")
        let version = cache.version

        fake.inputs = inputs([])
        cache.invalidate()
        await cache.idle()
        XCTAssertEqual(cache.model(forLinePath: line, documentPath: doc), .placeholder(.removed))
        XCTAssertNil(cache.model(forFigureId: cash.id))
        XCTAssertEqual(cache.version, version + 1, "the removal bumps the version")

        let twin = FigureRecord(id: "fig-1a1b2c3d", name: "cash2", kind: .table, piece: nil, path: "figures/Cash.csv")
        fake.inputs = inputs([(cash, table([1])), (twin, table([2]))])
        cache.invalidate()
        await cache.idle()
        XCTAssertEqual(cache.model(forLinePath: line, documentPath: doc), .placeholder(.ambiguous))

        var parked = table([1])
        parked.parked = FigureParking(path: "research/cash.csv", hash: "h")
        fake.inputs = inputs([(cash, parked)])
        cache.invalidate()
        await cache.idle()
        XCTAssertEqual(cache.model(forLinePath: line, documentPath: doc)?.kind, .parked)
    }

    // MARK: - In a window

    private var projectURL: URL!
    private var cacheURL: URL!

    private func openWindow() async throws -> (DocumentStore, ProjectStore) {
        projectURL = TestTemp.root.appendingPathComponent("figcards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        cacheURL = TestTemp.root.appendingPathComponent("figcards-cache-\(UUID().uuidString).json")
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: cacheURL, identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
        try "Words.\n".write(
            to: projectURL.appendingPathComponent("manuscript/a.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "piece-a", title: "A", type: .document, path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: projectURL.appendingPathComponent(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (store, projectStore)
    }

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        if let projectURL { try? FileManager.default.removeItem(at: projectURL) }
        if let cacheURL { try? FileManager.default.removeItem(at: cacheURL) }
    }

    /// Attached the way `EditorHost` attaches it.
    private func attach(_ cache: FigureCardCache, to store: DocumentStore) {
        store.attachFigureCardCache(cache)
        cache.attach(FigureCardCache.Source(read: { [weak store] in await store?.figureCardInputs() }))
    }

    /// **A real figure's card carries its computed values**, and an edit
    /// through its open host refills it (`figureHostAppended`) with one bump.
    func test_aWindowsFigureFillsWithItsValues_andAnEditRefills() async throws {
        let (store, projectStore) = try await openWindow()
        let record = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        let cache = FigureCardCache()
        attach(cache, to: store)
        await cache.idle()
        XCTAssertEqual(cache.model(forFigureId: record.id)?.kind, .table)
        XCTAssertEqual(cache.model(forFigureId: record.id)?.shownRowCount, 3)
        XCTAssertTrue(store.openFigures.isEmpty, "a fill opens no figure host")
        let version = cache.version

        let doc = try await store.openFigure(figureId: record.id)
        let key = CellKey(row: doc.state.table.rows[1], column: doc.state.table.columns[0])
        try await doc.setCell(Cell(content: .value(.number(42))), at: key)
        await cache.idle()
        XCTAssertEqual(cache.model(forFigureId: record.id)?.bodyRows[1].first, "42")
        XCTAssertEqual(cache.version, version + 1)
        await store.closeFigure(figureId: record.id)
        withExtendedLifetime(projectStore) {}
    }

    /// **Two windows on one project** (final review I1): both windows' caches
    /// hear an edit, and one window closing leaves the other refreshing.
    func test_twoWindowsOnOneProjectBothRefill_andClosingOneLeavesTheOther() async throws {
        let (store, projectStore) = try await openWindow()
        let record = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        let first = FigureCardCache()
        let second = FigureCardCache()
        attach(first, to: store)
        attach(second, to: store)
        await first.idle()
        await second.idle()

        let doc = try await store.openFigure(figureId: record.id)
        let key = CellKey(row: doc.state.table.rows[1], column: doc.state.table.columns[0])
        try await doc.setCell(Cell(content: .value(.number(42))), at: key)
        await first.idle()
        await second.idle()
        XCTAssertEqual(first.model(forFigureId: record.id)?.bodyRows[1].first, "42")
        XCTAssertEqual(second.model(forFigureId: record.id)?.bodyRows[1].first, "42",
                       "the second window does not take the first window's place")

        // The second window closes, the way `EditorHost.detachFigureCards` does.
        second.attach(nil)
        store.detachFigureCardCache(second)
        let version = first.version
        try await doc.setCell(Cell(content: .value(.number(7))), at: key)
        await first.idle()
        XCTAssertEqual(first.model(forFigureId: record.id)?.bodyRows[1].first, "7",
                       "the window still open keeps refreshing")
        XCTAssertEqual(first.version, version + 1)
        await store.closeFigure(figureId: record.id)
        withExtendedLifetime(projectStore) {}
    }

    /// **The window closing before a scheduled fill runs**: the cache stays
    /// attached, the store answers no inputs once its presenter is gone, so
    /// the fill lands nothing — and it leaves no figure host open.
    func test_aFillAfterTheWindowClosedLandsNothingAndLeavesNoHost() async throws {
        let (store, projectStore) = try await openWindow()
        _ = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        let cache = FigureCardCache()
        attach(cache, to: store)   // the fill is scheduled, not yet run
        await store.close()
        await cache.idle()          // still attached: only the nil inputs stop it
        XCTAssertEqual(cache.version, 0, "nothing landed")
        XCTAssertNil(cache.model(forLinePath: "../figures/cash.csv", documentPath: "manuscript/a.md"),
                     "not even a first fill")
        XCTAssertTrue(store.openFigures.isEmpty, "and no host was left open")
        let late = await store.figureCardInputs()
        XCTAssertNil(late, "a closed window answers no inputs")
        withExtendedLifetime(projectStore) {}
    }

    // MARK: - EditorHost's watches

    /// The manifest watches in `EditorHost` whose closure must refill the
    /// cards: the registry (a local create/rename/remove) and Research (a
    /// pin's source moving its card's flag). Each answer names a fault.
    static func watchFaults(in source: String) -> [String] {
        ["store.manifest.figures", "store.manifest.research"].compactMap { key in
            guard let start = source.range(of: ".onChange(of: \(key))") else {
                return "no .onChange(of: \(key))"
            }
            let rest = source[start.upperBound...]
            let body = rest.range(of: "\n        .").map { rest[..<$0.lowerBound] } ?? rest
            return body.contains("figureCards.invalidate()")
                ? nil : ".onChange(of: \(key)) does not refill the figure cards"
        }
    }

    func test_editorHostRefillsTheCardsWhenTheRegistryOrResearchChanges() throws {
        let source = try SourceTree.read("Maugham/Views/EditorHost.swift")
        XCTAssertEqual(Self.watchFaults(in: source), [])
    }

    /// `EditorHost` hands the editor the cached card (never a fill) by the
    /// line's path and this document's path, and pushes a new version
    /// through the control plane (report plan 7a Task 4).
    func test_editorHostWiresTheCardsIntoTheEditor() throws {
        let source = try SourceTree.read("Maugham/Views/EditorHost.swift")
        for needle in [
            "figureCards.model(forLinePath: linePath, documentPath: path)",
            "figureCards.onVersionChange = { control.figureCardVersion = $0 }",
        ] {
            XCTAssertTrue(source.contains(needle), "EditorHost no longer says: \(needle)")
        }
    }

    func test_theWatchCensusFiresOnAPlantedOffender() {
        let planted = """
                .onChange(of: store.manifest.research) { _, _ in referenceIndex.invalidate(.research) }
                .onChange(of: store.manifest.figures) { _, _ in figureCards.invalidate() }
                .onAppear { }
        """
        XCTAssertEqual(Self.watchFaults(in: planted),
                       [".onChange(of: store.manifest.research) does not refill the figure cards"])
        let control = """
                .onChange(of: store.manifest.research) { _, _ in
                    referenceIndex.invalidate(.research)
                    figureCards.invalidate()
                }
                .onChange(of: store.manifest.figures) { _, _ in figureCards.invalidate() }
                .onAppear { }
        """
        XCTAssertEqual(Self.watchFaults(in: control), [])
    }
}

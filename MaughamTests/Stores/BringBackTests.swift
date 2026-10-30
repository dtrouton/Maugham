import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **Coming back from Research** (report plan 6b Task 8, spec §4.2, ruling
/// P-7). *Use in document* on a parked figure's working copy brings that
/// figure back to its own log: an unchanged copy resumes it exactly, a changed
/// one appends its differences with matched rows keeping their ids — every op
/// signed by this Mac's author key and carrying `broughtBackFromResearch`, the
/// resume first. Three-way: a late edit the copy did not change survives.
@MainActor
final class BringBackTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("bringback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// A book with one chapter and a window over it.
    private func openBook() async throws -> (DocumentStore, ProjectStore) {
        try "Words.\n".write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await Document.load(url: file("manuscript/a.md"), actor: .author, session: "boot", presenter: nil)
        await doc.close()
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (store, projectStore)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private func external(_ name: String, _ data: Data) throws -> URL {
        let dir = TestTemp.root.appendingPathComponent("bringback-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// The budget figure, made from a Research CSV — a header row and four
    /// rows — and closed.
    private func budget(_ projectStore: ProjectStore) async throws -> FigureRecord {
        let source = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external(
                "budget.csv", Data("Item,Amount\nRent,1200.5\nFood,340\nTravel,99.9\nBooks,45\n".utf8)))
        return try await projectStore.useInDocument(researchItemId: source.id, piece: nil).record
    }

    /// Figure `id`'s stream, read windowless.
    private func state(_ id: String) async throws -> FigureState {
        let doc = try await FigureDocument.load(
            figureId: id, projectURL: projectURL, actor: .author,
            session: "read", presenter: nil, documentStore: nil)
        let state = doc.state
        await doc.close()
        return state
    }

    /// Every op in every file of the figure's stream, seals excluded, in op id order.
    private func ops(of figureId: String) throws -> [Op] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        return try OpLogStore.opLogFileURLs(forDocId: figureId, in: projectURL).flatMap { url in
            try Data(contentsOf: url)
                .split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
                .compactMap { line -> Op? in
                    let data = Data(line)
                    return OpLogChain.isSealLine(data) ? nil : try? dec.decode(Op.self, from: data)
                }
        }.sorted { $0.opId < $1.opId }
    }

    private func row(_ s: FigureState, labelled label: String) -> RowID? {
        let first = s.table.columns[0]
        return s.table.rows.first { s.table[CellKey(row: $0, column: first)]?.content == .value(.text(label)) }
    }

    /// A note anchored on `row` of figure `id`, as a reviewer leaves one.
    private func noteOn(_ id: String, row: RowID, column: ColumnID) async throws {
        try await OpLogStore(projectURL: projectURL).append(Op(
            opId: ULID.generate(), docId: id, at: Date(), device: "mac", session: "s",
            kind: .claudeComment, changes: [],
            provenance: Op.Provenance(sessionId: "s", annotationBody: "check", figureRowId: row.raw,
                                      figureColId: column.raw)))
    }

    /// The working copy, re-saved elsewhere with `bytes`.
    private func resave(_ item: ResearchItem, _ bytes: Data) throws {
        try bytes.write(to: file(try XCTUnwrap(item.path)))
    }

    /// The ops appended after the park, each checked for the reason and the
    /// signer, the resume first.
    private func appendedByTheReturn(_ id: String, after park: Op) throws -> [Op] {
        let appended = try ops(of: id).filter { $0.opId > park.opId }
        XCTAssertEqual(appended.first?.kind, .figureResumed, "the resume comes first (P-5)")
        for op in appended {
            XCTAssertEqual(op.provenance?.synthesisSource, .broughtBackFromResearch, "\(op.kind) carries the reason")
            XCTAssertEqual(op.device, Document.loadIdentities[.author].deviceId, "signed by whoever brings it back")
        }
        return appended
    }

    // MARK: - Unchanged

    /// An unchanged copy resumes the figure exactly: one `figureResumed`, the
    /// state as it was before the send, a note's row anchor still on a live
    /// row, the render back.
    func test_anUnchangedCopyResumesTheFigureExactly() async throws {
        let (store, projectStore) = try await openBook()
        let record = try await budget(projectStore)
        let before = try await state(record.id)
        let food = try XCTUnwrap(row(before, labelled: "Food"))
        try await noteOn(record.id, row: food, column: before.table.columns[1])

        let item = try await projectStore.sendToResearch(figureId: record.id, scope: .shared)
        let park = try XCTUnwrap(try ops(of: record.id).last)
        XCTAssertEqual(park.kind, .figureParked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(record.path).path))
        // The fast path holds: the parked state renders back to the park's
        // hash, so an unchanged figure's return needs no frontier.
        let parkedState = try await state(record.id)
        let names = try await store.formulaNamesForUse()
        XCTAssertEqual(
            ProjectStore.researchHash(of: parkedState.table, locale: TableLocale(languageTag: nil), names: names),
            park.figure?.parkedHash)

        let result = try await projectStore.useInDocument(researchItemId: item.id, piece: nil)

        XCTAssertEqual(result.record, record, "the figure keeps its record, so references reconnect")
        XCTAssertEqual(result.problems, [])
        XCTAssertEqual(result.overwritten, [])
        let appended = try appendedByTheReturn(record.id, after: park)
        XCTAssertEqual(appended.map(\.kind), [.figureResumed])
        let after = try await state(record.id)
        XCTAssertNil(after.parked)
        XCTAssertEqual(after.table, before.table, "ids, cells and formats as they were")
        // The note itself still resolves to its row: listed on the figure, and
        // its anchor names Food's row, live, labelled Food.
        let notes = projectStore.listAnnotationsAcrossProject().annotations.filter { $0.docId == record.id }
        XCTAssertEqual(notes.map(\.annotation.body), ["check"])
        let anchor = try XCTUnwrap(try ops(of: record.id).first { $0.kind == .claudeComment }?.provenance?.figureRowId)
        XCTAssertEqual(row(after, labelled: "Food"), RowID(anchor))
        XCTAssertTrue(projectStore.manifest.research.contains { $0.id == item.id }, "the copy stays in Research")
        await store.awaitOpenFigureRenderForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file(record.path).path), "the render is back")
        XCTAssertNil(store.openFigure(forId: record.id), "no host is left open")
    }

    // MARK: - Review Focus 3

    /// A working copy edited in Excel and re-saved — a byte-order mark, CRLF,
    /// `;` separators with decimal commas, a row inserted, one moved, one
    /// deleted — comes back with matched rows keeping their ids; only the
    /// deleted row's anchors are orphaned.
    func test_anExcelResavedCopyComesBackWithMatchedRowsKeepingTheirIds() async throws {
        let (store, projectStore) = try await openBook()
        defer { withExtendedLifetime(store) {} }   // ProjectStore holds its window weakly
        let record = try await budget(projectStore)
        let before = try await state(record.id)
        let ids = Dictionary(uniqueKeysWithValues: ["Item", "Rent", "Food", "Travel", "Books"].map {
            ($0, row(before, labelled: $0)!) })
        let amount = before.table.columns[1]
        try await noteOn(record.id, row: ids["Rent"]!, column: amount)
        try await noteOn(record.id, row: ids["Travel"]!, column: amount)
        let item = try await projectStore.sendToResearch(figureId: record.id, scope: .shared)
        let park = try XCTUnwrap(try ops(of: record.id).last)

        // Books to the top, Travel deleted, Phone after Food, Rent changed.
        try resave(item, Data("\u{FEFF}Item;Amount\r\nBooks;45\r\nRent;1250,5\r\nFood;340\r\nPhone;25,75\r\n".utf8))
        let result = try await projectStore.useInDocument(researchItemId: item.id, piece: nil)

        XCTAssertEqual(result.record.id, record.id)
        XCTAssertEqual(projectStore.manifest.figures?.count, 1, "no new figure")
        let after = try await state(record.id)
        XCTAssertNil(after.parked)
        let phone = try XCTUnwrap(row(after, labelled: "Phone"))
        XCTAssertEqual(after.table.rows, [ids["Item"]!, ids["Books"]!, ids["Rent"]!, ids["Food"]!, phone],
                       "matched rows keep their ids, in the copy's order")
        XCTAssertFalse(ids.values.contains(phone), "the inserted row has a fresh id")
        XCTAssertNotNil(after.table.rowIndex(of: ids["Rent"]!), "Rent's note stays anchored")
        XCTAssertNil(after.table.rowIndex(of: ids["Travel"]!), "only the deleted row's note is orphaned")
        XCTAssertEqual(after.table[CellKey(row: ids["Rent"]!, column: amount)]?.content, .value(.number(1250.5)))
        XCTAssertEqual(after.table.columns, before.table.columns)
        XCTAssertEqual(after.diagnostics, before.diagnostics, "every op the return appended applied")

        let appended = try appendedByTheReturn(record.id, after: park)
        let resume = try XCTUnwrap(appended.first)
        XCTAssertTrue(appended.dropFirst().allSatisfy { $0.figure?.returnOf == resume.opId },
                      "every op names its resume (final review M-2)")
        XCTAssertEqual(appended.filter { $0.kind == .figureStructure }.count, 3, "one delete, one move, one insert")
        XCTAssertEqual(appended.filter { $0.kind == .figureCellSet }.count, 3, "Rent's amount and Phone's two cells")
        XCTAssertEqual(appended.map(\.opId), appended.map(\.opId).sorted(), "each after the one before")
    }

    // MARK: - Three-way

    /// An edit that sorts before the park but that the parker never read (a
    /// skewed clock) is in the parked state and not in the copy: a changed copy
    /// that left that cell alone keeps it; one that changed it too wins, and
    /// the return says which cell.
    func test_aLateEditSurvivesAChangedCopyUnlessTheCopyChangedThatCell() async throws {
        let (store, projectStore) = try await openBook()
        let record = try await budget(projectStore)
        let other = try await admitAnotherMac(store)
        let before = try await state(record.id)
        let amount = before.table.columns[1]
        let food = CellKey(row: row(before, labelled: "Food")!, column: amount)
        let books = CellKey(row: row(before, labelled: "Books")!, column: amount)
        let item = try await projectStore.sendToResearch(figureId: record.id, scope: .shared)
        let park = try XCTUnwrap(try ops(of: record.id).last)
        let frontier = try XCTUnwrap(park.figure?.parkedFrontier)
        XCTAssertNil(frontier[other.author.deviceId], "the parker had read nothing of the other Mac's")

        // The other Mac's two edits, minted just before the park (its clock
        // behind): they sort before it and fold into the parked state.
        let early = try XCTUnwrap(ULID.timestampMillis(of: park.opId)) - 1
        for (key, value) in [(food, 999.0), (books, 777.0)] {
            try await theirCellSet(other, record.id, key, Cell(content: .value(.number(value))),
                                   prior: before.table[key], atMillis: early)
        }
        store.figureCache.invalidate(figureId: record.id)
        let parkedNow = try await state(record.id)
        XCTAssertEqual(parkedNow.table[food]?.content, .value(.number(999)))

        // The copy changed Books (late-edited too) and Rent; Food it left alone.
        try resave(item, Data("Item,Amount\nRent,1300\nFood,340\nTravel,99.9\nBooks,50\n".utf8))
        let result = try await projectStore.bringBack(researchItemId: item.id, piece: nil)

        let after = try await state(record.id)
        XCTAssertEqual(after.table[food]?.content, .value(.number(999)), "the late edit the copy left alone survives")
        XCTAssertEqual(after.table[books]?.content, .value(.number(50)), "the copy wins a cell both changed")
        XCTAssertEqual(result.overwritten, [books], "and the return says which")
        XCTAssertEqual(after.table[CellKey(row: row(after, labelled: "Rent")!, column: amount)]?.content,
                       .value(.number(1300)))
    }

    /// What the parker read of a stream is a prefix in APPEND order: an edit
    /// the other Mac appended after one the parker read, but whose id sorts
    /// lower (its clock stepped back), is not in what the copy was written
    /// from — the return leaves it standing.
    func test_anUnreadEditWhoseIdSortsBelowTheFrontierSurvives() async throws {
        let (store, projectStore) = try await openBook()
        let record = try await budget(projectStore)
        let other = try await admitAnotherMac(store)
        let before = try await state(record.id)
        let amount = before.table.columns[1]
        let food = CellKey(row: row(before, labelled: "Food")!, column: amount)
        let books = CellKey(row: row(before, labelled: "Books")!, column: amount)
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let read = try await theirCellSet(other, record.id, food, Cell(content: .value(.number(341))),
                                          prior: before.table[food], atMillis: now)
        let item = try await projectStore.sendToResearch(figureId: record.id, scope: .shared)
        let park = try XCTUnwrap(try ops(of: record.id).last)
        XCTAssertEqual(park.figure?.parkedFrontier?[other.author.deviceId], read.opId, "the parker read it")
        let unread = try await theirCellSet(other, record.id, books, Cell(content: .value(.number(46))),
                                            prior: before.table[books], atMillis: now - 1)
        XCTAssertLessThan(unread.opId, read.opId, "its id sorts below what was read")
        store.figureCache.invalidate(figureId: record.id)

        // The copy (as written: Food 341) changes only Rent.
        try resave(item, Data("Item,Amount\nRent,1300\nFood,341\nTravel,99.9\nBooks,45\n".utf8))
        let result = try await projectStore.bringBack(researchItemId: item.id, piece: nil)

        let after = try await state(record.id)
        XCTAssertEqual(after.table[books]?.content, .value(.number(46)), "the unread edit survives")
        XCTAssertEqual(after.table[food]?.content, .value(.number(341)))
        XCTAssertEqual(result.overwritten, [])
    }

    /// After a return whose ops were minted ahead of this Mac's clock (they
    /// follow another Mac's fast-clock edit), this Mac's next edit still sorts
    /// after them: last writer wins for the writer.
    func test_aLocalEditAfterAReturnSortsAfterIt() async throws {
        let (store, projectStore) = try await openBook()
        let record = try await budget(projectStore)
        let other = try await admitAnotherMac(store)
        let before = try await state(record.id)
        let food = CellKey(row: row(before, labelled: "Food")!, column: before.table.columns[1])
        let future = UInt64(Date().timeIntervalSince1970 * 1000) + 10 * 60_000
        try await theirCellSet(other, record.id, food, Cell(content: .value(.number(350))),
                               prior: before.table[food], atMillis: future)
        let item = try await projectStore.sendToResearch(figureId: record.id, scope: .shared)
        try resave(item, Data("Item,Amount\nRent,1300\nFood,350\nTravel,99.9\nBooks,45\n".utf8))
        _ = try await projectStore.bringBack(researchItemId: item.id, piece: nil)
        let newestReturned = try XCTUnwrap(try ops(of: record.id).last)
        XCTAssertEqual(newestReturned.provenance?.synthesisSource, .broughtBackFromResearch)

        let host = try await store.openFigure(figureId: record.id)
        try await host.setCell(Cell(content: .value(.number(360))), at: food)
        await store.closeFigure(figureId: record.id)
        let mine = try XCTUnwrap(try ops(of: record.id).last)
        XCTAssertEqual(mine.figure?.next?.content, .value(.number(360)), "the local edit sorts last")
        XCTAssertGreaterThan(mine.opId, newestReturned.opId)
        let after = try await state(record.id)
        XCTAssertEqual(after.table[food]?.content, .value(.number(360)))
    }

    /// A return whose append fails part way parks the figure again exactly as
    /// it was and says so; Use in document again brings back what was left —
    /// one Phone row, every matched id kept.
    func test_aReturnThatStopsPartWayIsParkedAgainAndARetryFinishesIt() async throws {
        let (store, projectStore) = try await openBook()
        defer { FigureDocument.beforeCommitAppendForTesting = nil }
        let record = try await budget(projectStore)
        let before = try await state(record.id)
        let ids = Dictionary(uniqueKeysWithValues: ["Item", "Rent", "Food", "Travel", "Books"].map {
            ($0, row(before, labelled: $0)!) })
        let item = try await projectStore.sendToResearch(figureId: record.id, scope: .shared)
        try resave(item, Data("\u{FEFF}Item;Amount\r\nBooks;45\r\nRent;1250,5\r\nFood;340\r\nPhone;25,75\r\n".utf8))

        var changesSeen = 0
        FigureDocument.beforeCommitAppendForTesting = { op in
            guard op.provenance?.synthesisSource == .broughtBackFromResearch, op.kind != .figureResumed else { return }
            changesSeen += 1
            if changesSeen == 2 { throw CocoaError(.fileWriteUnknown) }
        }
        do {
            _ = try await projectStore.useInDocument(researchItemId: item.id, piece: nil)
            XCTFail("the failed append was not said")
        } catch let incomplete as FigureBringBackIncomplete {
            XCTAssertEqual(incomplete.applied, 1)
            XCTAssertTrue(incomplete.parkedAgain)
            XCTAssertTrue(incomplete.localizedDescription.contains("put back in Research"))
        }
        let halfway = try await state(record.id)
        XCTAssertEqual(halfway.parked?.itemId, item.id, "parked again, as it was")
        XCTAssertNil(store.openFigure(forId: record.id), "no host is left open")

        FigureDocument.beforeCommitAppendForTesting = nil
        let result = try await projectStore.useInDocument(researchItemId: item.id, piece: nil)
        XCTAssertEqual(result.record.id, record.id, "the retry went back to the figure, no second one")
        XCTAssertEqual(projectStore.manifest.figures?.count, 1)
        let after = try await state(record.id)
        XCTAssertNil(after.parked)
        let phone = try XCTUnwrap(row(after, labelled: "Phone"))
        XCTAssertEqual(after.table.rows, [ids["Item"]!, ids["Books"]!, ids["Rent"]!, ids["Food"]!, phone])
        XCTAssertEqual(after.table[CellKey(row: ids["Rent"]!, column: after.table.columns[1])]?.content,
                       .value(.number(1250.5)))
    }

    // MARK: - Refusals

    /// Only the copy the park names brings a figure back: a second copy whose
    /// sidecar names the same figure is an orphan, and a figure not in
    /// Research is not brought back. Nothing is appended.
    func test_onlyTheParkedCopyBringsTheFigureBack() async throws {
        let (store, projectStore) = try await openBook()
        defer { withExtendedLifetime(store) {} }   // ProjectStore holds its window weakly
        let record = try await budget(projectStore)
        let item = try await projectStore.sendToResearch(figureId: record.id, scope: .shared)
        let orphan = try await projectStore.addResearchAsset(
            parentId: nil, fromURL: try external("orphan.csv", Data("Item,Amount\nRent,1\n".utf8)))
        try ResearchTableSidecar.write(
            ResearchTableSidecar(figureId: record.id, name: record.name), forItem: orphan.id, in: projectURL)
        let stream = try ops(of: record.id)

        do {
            _ = try await projectStore.bringBack(researchItemId: orphan.id, piece: nil)
            XCTFail("an orphan copy brought the figure back")
        } catch let refused as FigureReturnRefused {
            XCTAssertEqual(refused.reason, .notThisCopy)
        }
        XCTAssertEqual(try ops(of: record.id).map(\.opId), stream.map(\.opId), "nothing appended")
        let stillParked = try await state(record.id)
        XCTAssertNotNil(stillParked.parked)

        _ = try await projectStore.bringBack(researchItemId: item.id, piece: nil)
        do {
            _ = try await projectStore.bringBack(researchItemId: item.id, piece: nil)
            XCTFail("a figure not in Research was brought back")
        } catch let refused as FigureReturnRefused {
            XCTAssertEqual(refused.reason, .notParked)
        }
    }

    /// **A copy of an earlier park can't bring the figure back** (final
    /// re-review ruling): the figure came back from its first copy and was
    /// sent again, so Bring Back on the first copy is refused, saying the
    /// table was sent again since; nothing is appended and the second park
    /// stands. Each resume names the park it resumes. *Use in Document* on
    /// that copy routes to a new figure instead (8b final review M2,
    /// `ResearchFigureUseTests`).
    func test_aCopyOfAnEarlierParkIsRefusedSayingTheTableWasSentAgain() async throws {
        let (store, projectStore) = try await openBook()
        defer { withExtendedLifetime(store) {} }
        let record = try await budget(projectStore)
        let first = try await projectStore.sendToResearch(figureId: record.id, scope: .shared)
        _ = try await projectStore.bringBack(researchItemId: first.id, piece: nil)
        let resume = try XCTUnwrap(try ops(of: record.id).last { $0.kind == .figureResumed })
        XCTAssertEqual(resume.figure?.parkedItemId, first.id, "the resume names the park it resumes")
        let second = try await projectStore.sendToResearch(figureId: record.id, scope: .shared)
        let stream = try ops(of: record.id).map(\.opId)

        do {
            _ = try await projectStore.bringBack(researchItemId: first.id, piece: nil)
            XCTFail("an earlier park's copy brought the figure back")
        } catch let refused as FigureReturnRefused {
            XCTAssertEqual(refused.reason, .sentAgainSince(.table))
            XCTAssertEqual(refused.localizedDescription,
                           "This table was sent to Research again since this copy was made; bring it back from its newer copy.")
        }
        XCTAssertEqual(try ops(of: record.id).map(\.opId), stream, "nothing appended")
        let after = try await state(record.id)
        XCTAssertEqual(after.parked?.itemId, second.id, "the second park stands")
    }

    // MARK: - A picture

    /// A picture compares by hash: unchanged, it resumes; changed, its file in
    /// `figures/` takes the copy's bytes under its own name and one
    /// `figureImageSet` records the new hash.
    func test_aChangedPictureComesBackAsOneImageSet() async throws {
        let (store, projectStore) = try await openBook()
        defer { withExtendedLifetime(store) {} }   // ProjectStore holds its window weakly
        let map = try await projectStore.createImageFigure(fromURL: try png("map.png", .blue), piece: nil)
        let item = try await projectStore.sendToResearch(figureId: map.id, scope: .shared)
        let park = try XCTUnwrap(try ops(of: map.id).last)
        let parkedMap = try await state(map.id)
        let prior = try XCTUnwrap(parkedMap.image)

        try FileManager.default.removeItem(at: file(try XCTUnwrap(item.path)))
        try FileManager.default.copyItem(at: try png("map.png", .red), to: file(try XCTUnwrap(item.path)))
        let hash = try ContentHash.ofFile(file(try XCTUnwrap(item.path)))
        XCTAssertNotEqual(hash, prior.contentHash)

        let result = try await projectStore.useInDocument(researchItemId: item.id, piece: nil)

        XCTAssertEqual(result.record.id, map.id)
        let appended = try appendedByTheReturn(map.id, after: park)
        XCTAssertEqual(appended.map(\.kind), [.figureResumed, .figureImageSet])
        let after = try await state(map.id)
        XCTAssertEqual(after.image, FigureImageRef(filename: prior.filename, contentHash: hash))
        XCTAssertEqual(try ContentHash.ofFile(file("figures/\(prior.filename)")), hash, "the file holds the copy")
    }

    // MARK: - Helpers

    private func admitAnotherMac(_ store: DocumentStore) async throws -> LocalIdentities {
        let other = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: other.author.fingerprint, label: "Ada", ownName: "Ada’s Mac",
            permit: .author(.book))
        await store.postureSettled()
        return other
    }

    @discardableResult
    private func theirCellSet(
        _ other: LocalIdentities, _ id: String, _ key: CellKey, _ next: Cell, prior: Cell?, atMillis millis: UInt64
    ) async throws -> Op {
        let theirs = OpLogStore(
            projectURL: projectURL, identities: other,
            state: OpLogDeviceState(fileURL: projectURL.appendingPathComponent("other-\(UUID().uuidString).json")))
        let op = Op(
            opId: ULID.generate(atMillis: millis), docId: id, at: Date(), device: other.author.deviceId,
            session: "x", kind: .figureCellSet, changes: [],
            figure: FigureOpPayload(cell: key, next: next, prior: prior))
        try await theirs.append(op)
        _ = try await theirs.sealChain(docId: id)
        return op
    }

    private func png(_ name: String, _ colour: NSColor) throws -> URL {
        let dir = TestTemp.root.appendingPathComponent("bringback-png-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        colour.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let url = dir.appendingPathComponent(name)
        try ImagePasteHandler.encodePNG(image).write(to: url)
        return url
    }
}

import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **Send to Research** (report plan 6b Task 7, spec §4.2, rulings P-5 and
/// P-8). A figure is parked: its stream stays and is marked parked, a working
/// copy is written into Research (a CSV and its sidecar, or the picture), and
/// its line leaves the text. Every door is asked first, and a refusal changes
/// nothing. While parked the stream folds nothing: an edit ordered after the
/// park is dropped from the view and kept in history, and the host refuses
/// edits with "This table is in Research." (Review Focus 2).
@MainActor
final class SendToResearchTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("sendtoresearch-\(UUID().uuidString)")
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

    /// Chapters A and B with these bodies, each bootstrapped into its op log
    /// by this Mac's hand, and a window over the book.
    private func openBook(
        a: String = "Words.\n", b: String = "More words.\n"
    ) async throws -> (DocumentStore, ProjectStore) {
        for (slug, body) in [("a", a), ("b", b)] {
            try body.write(to: chapter(slug), atomically: true, encoding: .utf8)
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: ["a", "b"].map {
                StructureItem(id: "doc-\($0)", title: $0.uppercased(), type: .document,
                              path: "manuscript/\($0).md")
            },
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        for slug in ["a", "b"] {
            let doc = try await Document.load(url: chapter(slug), actor: .author, session: "boot", presenter: nil)
            await doc.close()
        }
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (store, projectStore)
    }

    private func chapter(_ slug: String) -> URL { file("manuscript/\(slug).md") }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: file(relative).path)
    }

    /// What a chapter says now, derived from its op log.
    private func text(_ slug: String) async throws -> String {
        let doc = try await Document.load(url: chapter(slug), actor: .author, session: "read", presenter: nil)
        let text = doc.displayText
        await doc.close()
        return text
    }

    private func csvRows(_ relative: String) throws -> [[String]] {
        let text = try String(contentsOf: file(relative), encoding: .utf8)  // adr-0018-ok: test reads the working copy and the derived render to assert what was written
        return TableCSV.rows(text).rows
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

    /// Every op in every file of the figure's stream, seals excluded.
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

    /// Another Mac, admitted as a whole-book author so its lines are read.
    private func admitAnotherMac(_ store: DocumentStore) async throws -> LocalIdentities {
        let other = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: other.author.fingerprint, label: "Ada", ownName: "Ada’s Mac",
            permit: .author(.book))
        await store.postureSettled()
        return other
    }

    /// `other`'s cell write on figure `id`, appended and sealed under its own
    /// identity — with an op id at `millis` when given (its clock).
    @discardableResult
    private func theirCellSet(
        _ other: LocalIdentities, _ id: String, _ key: CellKey, _ next: Cell, prior: Cell?,
        atMillis millis: UInt64? = nil
    ) async throws -> Op {
        let theirs = OpLogStore(
            projectURL: projectURL, identities: other,
            state: OpLogDeviceState(fileURL: projectURL.appendingPathComponent("other-\(UUID().uuidString).json")))
        let op = Op(
            opId: millis.map { ULID.generate(atMillis: $0) } ?? ULID.generate(),
            docId: id, at: Date(), device: other.author.deviceId,
            session: "x", kind: .figureCellSet, changes: [],
            figure: FigureOpPayload(cell: key, next: next, prior: prior))
        try await theirs.append(op)
        _ = try await theirs.sealChain(docId: id)
        return op
    }

    private func number(_ x: Double) -> Cell { Cell(content: .value(.number(x))) }

    /// `cash` (a header row, A1 "Month", B1 a percentage-formatted 0.25, A2
    /// 5) and `total`, whose A1 reads `cash!A2*2`; both closed.
    private func cashAndTotal(
        _ store: DocumentStore, _ projectStore: ProjectStore, piece: String? = nil
    ) async throws -> (cash: FigureRecord, total: FigureRecord, a2: CellKey) {
        let cash = try await projectStore.createFigure(kind: .table, name: "cash", piece: piece)
        let total = try await projectStore.createFigure(kind: .table, name: "total", piece: nil)
        let cashDoc = try await store.openFigure(figureId: cash.id)
        let rows = cashDoc.state.table.rows, columns = cashDoc.state.table.columns
        try await cashDoc.setCell(Cell(content: .value(.text("Month"))), at: CellKey(row: rows[0], column: columns[0]))
        var share = number(0.25)
        share.format = CellFormat(number: .percent(decimals: 0))
        try await cashDoc.setCell(share, at: CellKey(row: rows[0], column: columns[1]))
        let a2 = CellKey(row: rows[1], column: columns[0])
        try await cashDoc.setCell(number(5), at: a2)
        try await cashDoc.setHeaderRows(1)
        let totalDoc = try await store.openFigure(figureId: total.id)
        let t1 = CellKey(row: totalDoc.state.table.rows[0], column: totalDoc.state.table.columns[0])
        let names = FormulaNames(figures: [.init(id: cash.id, name: "cash", table: cashDoc.state.table)])
        guard case .success(let f) = FormulaParser.parse("cash!A2*2", in: totalDoc.state.table, names: names)
        else { throw FigureEditInvalid(reason: "the formula did not parse") }
        try await totalDoc.setCell(Cell(content: .formula(f)), at: t1)
        await store.closeFigure(figureId: cash.id)
        await store.closeFigure(figureId: total.id)
        await store.awaitOpenFigureRenderForTesting()
        return (cash, total, a2)
    }

    private let cashLine = "![Cash flow](../figures/cash.csv){#tbl:cash}"

    // MARK: - A send

    /// **A send writes the CSV and its sidecar, removes the line, keeps the
    /// stream, and a figure reading it still shows its value.**
    func test_aSendWritesTheCSVAndSidecar_removesTheLine_keepsTheStream_andAReaderKeepsTheValue() async throws {
        let (store, projectStore) = try await openBook(
            a: "Intro.\n\n\(cashLine)\n\nAfter.\n", b: "See @tbl:cash.\n")
        let (cash, total, a2) = try await cashAndTotal(store, projectStore)
        XCTAssertEqual(try csvRows("figures/total.csv").first?.first, "10", "precondition: total reads cash")
        let before = try ops(of: cash.id)

        let item = try await projectStore.sendToResearch(figureId: cash.id, scope: .shared)

        // The working copy, in Research.
        XCTAssertEqual(item.kind, .table)
        XCTAssertEqual(item.title, "cash")
        let path = try XCTUnwrap(item.path)
        XCTAssertEqual(projectStore.manifest.research.map(\.id), [item.id])
        XCTAssertEqual(try csvRows(path), [["Month", "0.25", ""], ["5", "", ""], ["", "", ""]])
        let sidecar = try XCTUnwrap(try ResearchTableSidecar.read(forItem: item.id, in: projectURL))
        let hash = try ContentHash.ofFile(file(path))
        XCTAssertEqual(sidecar.figureId, cash.id)
        XCTAssertEqual(sidecar.name, "cash")
        XCTAssertEqual(sidecar.caption, "Cash flow", "the caption comes from the line that left the text")
        XCTAssertEqual(sidecar.contentHash, hash)
        XCTAssertEqual(sidecar.headerRows, 1)
        XCTAssertEqual(sidecar.formats, [.init(row: 0, column: 1, format: CellFormat(number: .percent(decimals: 0)))])

        // The stream: kept, and parked by one op naming the copy.
        let after = try ops(of: cash.id)
        XCTAssertEqual(after.count, before.count + 1)
        let park = try XCTUnwrap(after.last)
        XCTAssertEqual(park.kind, .figureParked)
        XCTAssertEqual(park.figure?.parkedPath, path)
        XCTAssertEqual(park.figure?.parkedHash, hash)
        XCTAssertEqual(park.figure?.parkedItemId, item.id)
        let parked = try await state(cash.id)
        XCTAssertEqual(parked.parked, FigureParking(path: path, hash: hash, itemId: item.id))
        XCTAssertEqual(parked.table[a2], number(5))
        XCTAssertEqual(projectStore.manifest.figures?.map(\.id), [cash.id, total.id], "it stays in the registry")

        // The text: the line gone with one blank line left; the reference kept.
        let a = try await text("a")
        XCTAssertEqual(a, "Intro.\n\nAfter.")
        let b = try await text("b")
        XCTAssertEqual(b, "See @tbl:cash.", "a reference elsewhere is left (it reads as in Research)")

        // Its render is gone; the reader keeps its value.
        XCTAssertFalse(exists("figures/cash.csv"), "the stale render went to the Trash")
        await store.awaitOpenFigureRenderForTesting()
        XCTAssertEqual(try csvRows("figures/total.csv").first?.first, "10", "total keeps cash's parked value")
        XCTAssertEqual(store.lastParkedFigures, [cash.id])

        // The host refuses edits.
        let host = try await store.openFigure(figureId: cash.id)
        do {
            try await host.setCell(number(9), at: a2)
            XCTFail("a parked figure took an edit")
        } catch let refused as FigureParkedRefused {
            XCTAssertEqual(refused.localizedDescription, "This table is in Research.")
        }
        XCTAssertEqual(try ops(of: cash.id).count, after.count, "nothing was appended")

        // And it cannot be sent twice.
        do {
            _ = try await projectStore.sendToResearch(figureId: cash.id, scope: .shared)
            XCTFail("a parked figure was sent again")
        } catch let refused as FigureSendRefused {
            XCTAssertEqual(refused.reason, .alreadyInResearch)
        }
        await store.closeFigure(figureId: cash.id)
    }

    /// An image figure's working copy is its picture; it stays in `figures/`
    /// for the return, and a figure with no line in the text needs no text door.
    func test_aPictureIsSentAsACopyOfItsFile() async throws {
        let (store, projectStore) = try await openBook()
        let picture = try png("map.png")
        let map = try await projectStore.createImageFigure(fromURL: picture, piece: nil)

        let item = try await projectStore.sendToResearch(figureId: map.id, scope: .shared)

        XCTAssertEqual(item.kind, .image)
        let path = try XCTUnwrap(item.path)
        let hash = try ContentHash.ofFile(file(path))
        XCTAssertEqual(hash, try ContentHash.ofFile(file(map.path)), "the copy is the picture")
        XCTAssertNil(try ResearchTableSidecar.read(forItem: item.id, in: projectURL), "a picture has no sidecar")
        let s = try await state(map.id)
        XCTAssertEqual(s.parked, FigureParking(path: path, hash: hash, itemId: item.id))
        let host = try await store.openFigure(figureId: map.id)
        do {
            try await host.setImage(fromURL: picture)
            XCTFail("a parked picture took a new file")
        } catch let refused as FigureParkedRefused {
            XCTAssertEqual(refused.localizedDescription, "This picture is in Research.")
        }
        await store.closeFigure(figureId: map.id)
    }

    /// Ruling P-8: the park itself registers no ⌘Z, and an edit's ⌘Z made
    /// before the send declines once the figure is parked — said with the
    /// parked notice, nothing appended.
    func test_anUndoAfterTheSendDeclinesWithTheParkedNotice() async throws {
        let (store, projectStore) = try await openBook(a: "\(cashLine)\n")
        let (cash, _, a2) = try await cashAndTotal(store, projectStore)
        let host = try await store.openFigure(figureId: cash.id)
        let um = UndoManager()
        try await host.setCell(number(6), at: a2, undoManager: um)
        _ = try await projectStore.sendToResearch(figureId: cash.id, scope: .shared)
        XCTAssertNotNil(host.state.parked, "precondition: the open host parked it")
        let count = try ops(of: cash.id).count

        var said: [String] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { note in
            if let m = note.userInfo?[MaughamEvent.noticeMessageKey] as? String { said.append(m) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        XCTAssertTrue(um.canUndo, "the edit's undo is still on the stack (the park added none)")
        um.undo()
        await host.awaitPendingUndoWork()
        XCTAssertEqual(said, ["This table is in Research."])
        XCTAssertEqual(try ops(of: cash.id).count, count, "nothing was appended")
        XCTAssertEqual(host.state.table[a2], number(6))
        await store.closeFigure(figureId: cash.id)
    }

    // MARK: - Refusals change nothing

    /// **A send refused by the text door changes nothing**: the figure's line
    /// is in B, which this Mac yields to Sam. Research, the sidecar folder,
    /// the stream, the render and both texts are as they were; after *Edit
    /// Anyway* on B the send goes through.
    func test_aSendRefusedByTheTextDoorChangesNothing() async throws {
        let (store, projectStore) = try await openBook(a: "Words.\n", b: "\(cashLine)\n")
        let (cash, _, _) = try await cashAndTotal(store, projectStore)
        let sam = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces(["doc-b"])))
        await store.postureSettled()
        XCTAssertEqual(store.posture(forDocId: "doc-b").yieldingTo, "Sam", "precondition: this Mac yields on B")
        let streamBefore = try ops(of: cash.id)

        do {
            _ = try await projectStore.sendToResearch(figureId: cash.id, scope: .shared)
            XCTFail("the send was not refused")
        } catch let refused as FigureSendRefused {
            XCTAssertEqual(refused.reason, .piecesNotWritable(["B"]))
            XCTAssertTrue(refused.localizedDescription.contains("B"))
        }
        XCTAssertEqual(projectStore.manifest.research, [], "nothing in Research")
        XCTAssertFalse(exists(ResearchTableSidecar.folder), "no sidecar")
        XCTAssertFalse(exists("research"), "no working copy")
        XCTAssertEqual(try ops(of: cash.id), streamBefore, "nothing appended")
        let refusedState = try await state(cash.id)
        XCTAssertNil(refusedState.parked)
        XCTAssertTrue(exists("figures/cash.csv"), "its render stands")
        let b = try await text("b")
        XCTAssertEqual(b, cashLine, "its line stands")
        XCTAssertNil(store.openFigure(forId: cash.id), "no host was left open")

        store.overrideYield(docId: "doc-b")
        _ = try await projectStore.sendToResearch(figureId: cash.id, scope: .shared)
        let sent = try await text("b")
        XCTAssertEqual(sent, "", "Edit Anyway: B's line leaves")
    }

    /// A figure this Mac may not change is not sent, at its own door.
    func test_aFigureThisMacMayNotChangeIsNotSent() async throws {
        let (store, projectStore) = try await openBook()
        let prices = try await projectStore.createFigure(kind: .table, name: "prices", piece: "doc-b")
        let sam = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces(["doc-b"])))
        await store.postureSettled()

        do {
            _ = try await projectStore.sendToResearch(figureId: prices.id, scope: .shared)
            XCTFail("the send was not refused")
        } catch let refused as FigureEditRefused {
            XCTAssertEqual(refused.site, "sendToResearch")
        }
        XCTAssertEqual(projectStore.manifest.research, [])
        let s = try await state(prices.id)
        XCTAssertNil(s.parked)
    }

    /// A send whose park finds the figure changed since its copy was made
    /// takes the copy back out, and the text keeps its line.
    func test_aFigureThatChangesWhileItsCopyIsWrittenIsNotSent() async throws {
        let (store, projectStore) = try await openBook(a: "\(cashLine)\n")
        let (cash, _, a2) = try await cashAndTotal(store, projectStore)
        let host = try await store.openFigure(figureId: cash.id)
        // Lands while the copy is written: the first await after the snapshot.
        ProjectStore.beforeSendParksForTesting = { _ in try await host.setCell(Cell(content: .value(.number(6))), at: a2) }
        defer { ProjectStore.beforeSendParksForTesting = nil }

        do {
            _ = try await projectStore.sendToResearch(figureId: cash.id, scope: .shared)
            XCTFail("the send was not refused")
        } catch let invalid as FigureEditInvalid {
            XCTAssertEqual(invalid.reason, "the figure changed while it was being sent to Research")
        }
        XCTAssertEqual(projectStore.manifest.research, [], "the copy was taken back out")
        let research = (try? FileManager.default.contentsOfDirectory(atPath: file("research").path)) ?? []
        XCTAssertEqual(research, [], "its file too")
        let sidecars = (try? FileManager.default.contentsOfDirectory(atPath: file(ResearchTableSidecar.folder).path)) ?? []
        XCTAssertEqual(sidecars, [], "and its sidecar")
        XCTAssertNil(host.state.parked)
        XCTAssertEqual(host.state.table[a2], number(6), "the edit stands")
        let a = try await text("a")
        XCTAssertEqual(a, cashLine, "the line stays")
        await store.closeFigure(figureId: cash.id)
    }

    // MARK: - Review Focus 2: two hosts

    /// **The text door closing during the park step** (review Minor 7): B's
    /// held document stops being writable after the hold, so `held.write()`
    /// throws inside the park's synchronous step. Nothing changes: no park
    /// op, B's line intact, the copy and its sidecar taken back out.
    func test_aTextDoorClosingDuringTheParkChangesNothing() async throws {
        let (store, projectStore) = try await openBook(a: "Words.\n", b: "\(cashLine)\n")
        let (cash, _, _) = try await cashAndTotal(store, projectStore)
        let streamBefore = try ops(of: cash.id)
        ProjectStore.beforeSendParksForTesting = { held in
            if let b = held?.manuscripts.first(where: { $0.title == "B" }) { await b.manuscript.doc.close() }
        }
        defer { ProjectStore.beforeSendParksForTesting = nil }

        do {
            _ = try await projectStore.sendToResearch(figureId: cash.id, scope: .shared)
            XCTFail("the send was not refused")
        } catch let refused as FigureSendRefused {
            XCTAssertEqual(refused.reason, .piecesNotWritable(["B"]))
        }
        ProjectStore.beforeSendParksForTesting = nil
        XCTAssertEqual(try ops(of: cash.id), streamBefore, "no park op")
        let s = try await state(cash.id)
        XCTAssertNil(s.parked)
        XCTAssertEqual(projectStore.manifest.research, [], "the copy was taken back out")
        let research = (try? FileManager.default.contentsOfDirectory(atPath: file("research").path)) ?? []
        XCTAssertEqual(research, [], "its file too")
        let sidecars = (try? FileManager.default.contentsOfDirectory(atPath: file(ResearchTableSidecar.folder).path)) ?? []
        XCTAssertEqual(sidecars, [], "and its sidecar")
        XCTAssertTrue(exists("figures/cash.csv"), "its render stands")
        let b = try await text("b")
        XCTAssertEqual(b, cashLine, "B's line is intact")
        XCTAssertNil(store.openFigure(forId: cash.id), "no host was left open")
    }

    /// **Review Focus 2.** Two hosts on one figure: the window's sends it to
    /// Research while another, opened before the send, edits a cell. The
    /// edit is ordered after the park, so it is dropped from the view —
    /// on both hosts and on a fresh read, which agree — and kept in history;
    /// the working copy holds the parker's state; nothing crashes.
    func test_twoHosts_anEditOrderedAfterTheParkIsDroppedAndKeptInHistory() async throws {
        let (store, projectStore) = try await openBook(a: "\(cashLine)\n")
        let (cash, total, a2) = try await cashAndTotal(store, projectStore)
        let other = try await FigureDocument.load(
            figureId: cash.id, projectURL: projectURL, actor: .author,
            session: "other", presenter: nil, documentStore: nil)
        XCTAssertNil(other.state.parked, "precondition: the other host has not seen a park")

        let item = try await projectStore.sendToResearch(figureId: cash.id, scope: .shared)
        let window = try await store.openFigure(figureId: cash.id)

        // The other host has not read the park: its edit appends.
        try await other.setCell(number(7), at: a2)
        let edit = try XCTUnwrap(try ops(of: cash.id).last)
        XCTAssertEqual(edit.kind, .figureCellSet, "the edit is in history")
        XCTAssertEqual(edit.figure?.next, number(7))
        XCTAssertGreaterThan(edit.opId, try XCTUnwrap(try ops(of: cash.id).first { $0.kind == .figureParked }).opId,
                             "and ordered after the park")

        try await other.reload()
        try await window.reload()
        let fresh = try await state(cash.id)
        for (who, s) in [("the other host", other.state), ("the window's host", window.state), ("a fresh read", fresh)] {
            XCTAssertEqual(s.table[a2], number(5), "\(who): the parker's value stands")
            XCTAssertNotNil(s.parked, "\(who): parked")
            XCTAssertEqual(
                s.diagnostics, ["\(edit.opId): figure_cell_set while the figure is parked in Research, not applied"],
                "\(who): the edit is dropped from the view, said")
        }
        XCTAssertEqual(other.state, fresh)
        XCTAssertEqual(window.state, fresh)
        XCTAssertEqual(try csvRows(try XCTUnwrap(item.path))[1].first, "5", "the working copy holds the parker's state")

        // The figure reading it ignores the dropped edit too (review Minor 4).
        await store.renderFigures(changed: [cash.id])
        await store.awaitOpenFigureRenderForTesting()
        XCTAssertEqual(try csvRows(total.path).first?.first, "10", "total still reads cash's parked 5")

        // Now that it has read the park, the other host refuses.
        do {
            try await other.setCell(number(8), at: a2)
            XCTFail("a parked figure took an edit")
        } catch is FigureParkedRefused {}
        await other.close()
        await store.closeFigure(figureId: cash.id)
    }

    /// **Review Focus 2, the other arrival order.** Another Mac's edit, made
    /// on a clock running ten minutes fast, arrives and is read by the
    /// parker before the send: the copy holds it, so the park sorts after it
    /// and the parked state holds it too — nothing is dropped, and copy and
    /// stream agree. A later edit from that same fast clock, arriving after
    /// the park, sorts after it and is dropped.
    func test_anEditFromAFastClockThatTheParkerHadReadIsInTheCopyAndTheParkedState() async throws {
        let (store, projectStore) = try await openBook(a: "\(cashLine)\n")
        let (cash, _, a2) = try await cashAndTotal(store, projectStore)
        let ada = try await admitAnotherMac(store)
        let fast = UInt64(Date().timeIntervalSince1970 * 1000) + 600_000
        let theirs = try await theirCellSet(ada, cash.id, a2, number(7), prior: number(5), atMillis: fast)
        let window = try await store.openFigure(figureId: cash.id)
        try await window.reload()
        XCTAssertEqual(window.state.table[a2], number(7), "precondition: the parker has read their edit")

        let item = try await projectStore.sendToResearch(figureId: cash.id, scope: .shared)

        let park = try XCTUnwrap(try ops(of: cash.id).first { $0.kind == .figureParked })
        XCTAssertGreaterThan(park.opId, theirs.opId, "the park sorts after what the parker had read")
        let fresh = try await state(cash.id)
        XCTAssertEqual(fresh.table[a2], number(7), "the parked state holds their edit")
        XCTAssertEqual(fresh.diagnostics, [])
        XCTAssertEqual(try csvRows(try XCTUnwrap(item.path))[1].first, "7", "and so does the copy")

        let late = try await theirCellSet(ada, cash.id, a2, number(8), prior: number(7), atMillis: fast + 60_000)
        try await window.reload()
        let after = try await state(cash.id)
        XCTAssertEqual(window.state, after, "the host and a fresh read agree")
        XCTAssertEqual(after.table[a2], number(7))
        XCTAssertEqual(after.diagnostics, ["\(late.opId): figure_cell_set while the figure is parked in Research, not applied"])
        await store.closeFigure(figureId: cash.id)
    }

    // MARK: - Helpers

    /// A real PNG outside the project.
    private func png(_ name: String) throws -> URL {
        let dir = TestTemp.root.appendingPathComponent("send-png-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let url = dir.appendingPathComponent(name)
        try ImagePasteHandler.encodePNG(image).write(to: url)
        return url
    }
}

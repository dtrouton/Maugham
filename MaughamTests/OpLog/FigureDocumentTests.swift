import XCTest
@testable import Maugham
@testable import MaughamCore

/// **The figure host** (report plan 6a Task 6): a figure is created through
/// `ProjectStore.createFigure`, opened through `FigureDocument.load` (which
/// writes nothing), and changed only through mutators that ask the FIGURE's
/// posture first, append one op carrying what it replaced, and register a
/// drift-guarded ⌘Z.
@MainActor
final class FigureDocumentTests: XCTestCase {

    private var projectURL: URL!
    private var identities: LocalIdentities!
    private var cacheURL: URL!

    private static let pieceA = "piece-a"
    private static let pieceB = "piece-b"

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("figdoc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        cacheURL = TestTemp.root.appendingPathComponent("figdoc-cache-\(UUID().uuidString).json")
        identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: cacheURL, identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
        try makeProject()
    }

    override func tearDown() async throws {
        ProjectStore.beforeFigureAppendForTesting = nil
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: - Fixture

    private func makeProject() throws {
        for path in ["manuscript/a.md", "manuscript/b.md"] {
            try "Words.\n".write(
                to: projectURL.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [
                StructureItem(id: Self.pieceA, title: "A", type: .document, path: "manuscript/a.md"),
                StructureItem(id: Self.pieceB, title: "B", type: .document, path: "manuscript/b.md"),
            ],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: projectURL.appendingPathComponent(ProjectManifest.fileName))
    }

    private func load(_ id: String, as actor: DeviceActor = .author) async throws -> FigureDocument {
        try await FigureDocument.load(
            figureId: id, projectURL: projectURL, actor: actor, session: "s", presenter: nil)
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
        }
    }

    /// The bytes of every file of the stream, by name.
    private func streamBytes(of figureId: String) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for url in OpLogStore.opLogFileURLs(forDocId: figureId, in: projectURL) {
            out[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return out
    }

    private func text(_ s: String) -> Cell { Cell(content: .value(.text(s))) }

    private func firstKey(_ doc: FigureDocument) throws -> CellKey {
        CellKey(row: try XCTUnwrap(doc.state.table.rows.first),
                column: try XCTUnwrap(doc.state.table.columns.first))
    }

    private func notices(during body: () async throws -> Void) async rethrows -> [String] {
        var seen: [String] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { note in
            if let m = note.userInfo?[MaughamEvent.noticeMessageKey] as? String { seen.append(m) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try await body()
        return seen
    }

    // MARK: - Create and load

    func test_createThenLoad_isAThreeByThreeTableWithNoHeaderRow() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "cashflow", piece: Self.pieceA)

        XCTAssertTrue(record.id.hasPrefix("fig-"), "a figure's id is minted, never its name")
        XCTAssertEqual(record.name, "cashflow")
        XCTAssertEqual(record.path, "figures/cashflow.csv")
        XCTAssertEqual(record.piece, Self.pieceA)
        let onDisk = try ProjectManifest.makeDecoder().decode(
            ProjectManifest.self,
            from: Data(contentsOf: projectURL.appendingPathComponent(ProjectManifest.fileName)))
        XCTAssertEqual(onDisk.figures, [record], "the record went through the manifest door")
        XCTAssertEqual(
            ProjectManifest.schemaVersion(
                ofFileAt: projectURL.appendingPathComponent(ProjectManifest.fileName)), 10,
            "a manifest with figures carries the content floor")

        let doc = try await load(record.id)
        XCTAssertEqual(doc.state.kind, .table)
        XCTAssertEqual(doc.state.table.rows.count, 3)
        XCTAssertEqual(doc.state.table.columns.count, 3)
        XCTAssertEqual(doc.state.table.headerRows, 0)
        XCTAssertEqual(doc.state.diagnostics, [])
        XCTAssertEqual(doc.state.createdBy, identities.author.deviceId,
                       "created by this device's author")
        await doc.close()
    }

    func test_aSecondFigureOfTheSameNameIsDeduplicatedAndKeepsItsBareShape() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let first = try await store.createFigure(kind: .table, name: "cashflow", piece: nil)
        let second = try await store.createFigure(kind: .table, name: "CashFlow", piece: nil)
        XCTAssertEqual(first.name, "cashflow")
        XCTAssertEqual(second.name, "CashFlow_2", "case-insensitive, as the render files are")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(store.manifest.figures?.count, 2)
    }

    func test_loadEmitsNoOp() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let before = try streamBytes(of: record.id)
        let opsBefore = try ops(of: record.id).count

        let doc = try await load(record.id)
        XCTAssertEqual(try streamBytes(of: record.id), before, "the load wrote nothing at all")
        XCTAssertEqual(try ops(of: record.id).count, opsBefore)
        let assistant = try await load(record.id, as: .assistant)
        XCTAssertEqual(try ops(of: record.id).count, opsBefore, "nor through another actor's door")
        XCTAssertEqual(assistant.state.table.rows.count, 3)
        await doc.close()
        await assistant.close()
    }

    // MARK: - Mutation

    func test_setCellAppendsOneOpCarryingThePriorCell() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let key = try firstKey(doc)

        try await doc.setCell(text("one"), at: key, undoManager: nil)
        let count = try ops(of: record.id).count
        try await doc.setCell(text("two"), at: key, undoManager: nil)

        let all = try ops(of: record.id)
        XCTAssertEqual(all.count, count + 1, "one op per edit")
        let last = try XCTUnwrap(all.last)
        XCTAssertEqual(last.kind, .figureCellSet)
        XCTAssertEqual(last.device, identities.author.deviceId)
        XCTAssertEqual(last.figure?.cell, key)
        XCTAssertEqual(last.figure?.prior, text("one"), "prior is the cell it replaced")
        XCTAssertEqual(last.figure?.next, text("two"))
        XCTAssertEqual(doc.state.table[key], text("two"))

        // And a fresh load reads what was written.
        let reread = try await load(record.id)
        XCTAssertEqual(reread.state.table[key], text("two"))
        await doc.close()
        await reread.close()
    }

    func test_undoAppendsTheInverseAndRestoresIt_redoReappliesIt() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let key = try firstKey(doc)
        let um = UndoManager()

        try await doc.setCell(text("one"), at: key, undoManager: um)
        XCTAssertTrue(um.canUndo)
        let afterEdit = try ops(of: record.id).count

        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertNil(doc.state.table[key], "undo restored the empty cell")
        let undone = try ops(of: record.id)
        XCTAssertEqual(undone.count, afterEdit + 1, "undo APPENDS a compensating op")
        XCTAssertEqual(undone.last?.figure?.next, nil)
        XCTAssertEqual(undone.last?.figure?.prior, text("one"))
        XCTAssertTrue(um.canRedo)

        um.redo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.state.table[key], text("one"), "redo re-applies it")
        XCTAssertEqual(try ops(of: record.id).count, afterEdit + 2)
        XCTAssertTrue(um.canUndo, "and the redo is undoable again")
        await doc.close()
    }

    func test_settingsAndMovesUndoToWhatTheyReplaced() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let um = UndoManager()
        um.groupsByEvent = false
        let rows = doc.state.table.rows

        um.beginUndoGrouping()
        try await doc.setHeaderRows(1, undoManager: um)
        um.endUndoGrouping()
        um.beginUndoGrouping()
        try await doc.moveRow(rows[0], after: rows[2], undoManager: um)
        um.endUndoGrouping()
        XCTAssertEqual(doc.state.table.headerRows, 1)
        XCTAssertEqual(doc.state.table.rows, [rows[1], rows[2], rows[0]])

        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.state.table.rows, rows, "the move went back")
        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.state.table.headerRows, 0, "the setting went back")
        await doc.close()
    }

    func test_anInsertUndoesToADeleteAndDeclinesItsRedo_aDeleteRegistersNoUndo() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let um = UndoManager()

        let row = try await doc.insertRow(after: doc.state.table.rows.last, undoManager: um)
        XCTAssertEqual(doc.state.table.rows.count, 4)
        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertNil(doc.state.table.rowIndex(of: row), "undo deleted the inserted row")
        let count = try ops(of: record.id).count

        let said = await notices {
            um.redo()
            await doc.awaitPendingUndoWork()
        }
        XCTAssertEqual(said.count, 1, "the declined redo is said: \(said)")
        XCTAssertEqual(try ops(of: record.id).count, count, "and writes nothing (ruling R-6a-5)")

        // A delete takes no undo manager at all: 6a cannot revive a tombstone.
        try await doc.deleteRow(doc.state.table.rows[0])
        try await doc.deleteColumn(doc.state.table.columns[0])
        XCTAssertEqual(doc.state.table.rows.count, 2)
        XCTAssertEqual(doc.state.table.columns.count, 2)
        await doc.close()
    }

    /// **Review Focus 5**: an undo whose cell another device has since
    /// rewritten declines, rather than clobber the other device's value.
    func test_undoOfACellAnotherDeviceRewroteDeclines() async throws {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let key = try firstKey(doc)
        let um = UndoManager()
        try await doc.setCell(text("mine"), at: key, undoManager: um)

        let other = LocalIdentities.softwareForTesting()
        let theirs = OpLogStore(
            projectURL: projectURL, identities: other,
            state: OpLogDeviceState(fileURL: projectURL.appendingPathComponent("other-state.json")))
        try await theirs.append(Op(
            opId: ULID.generate(), docId: record.id, at: Date(), device: other.author.deviceId,
            session: "x", kind: .figureCellSet, changes: [],
            figure: FigureOpPayload(cell: key, next: text("theirs"), prior: text("mine"))))
        _ = try await theirs.sealChain(docId: record.id)
        try await doc.reload()
        XCTAssertEqual(doc.state.table[key], text("theirs"), "precondition: their write arrived")
        let count = try ops(of: record.id).count

        let said = await notices {
            um.undo()
            await doc.awaitPendingUndoWork()
        }
        XCTAssertEqual(said, ["Couldn't undo the change to the table — it changed on another device."])
        XCTAssertEqual(doc.state.table[key], text("theirs"), "their value stands")
        XCTAssertEqual(try ops(of: record.id).count, count, "nothing was appended")
        await doc.close()
    }

    // MARK: - Registry fixtures

    /// A foreign root that admits this device as a book author.
    private func makeForeignRoot() throws -> DeviceIdentity {
        let root = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(
            DeviceRecord(
                device: root.fingerprint, name: "The other Mac", kind: .mac,
                actors: [DeviceActor.author.rawValue: root.fingerprint],
                madeAt: Date(timeIntervalSince1970: 1_000)),
            signedBy: root, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: root.fingerprint, label: "Sam", ownName: "The other Mac",
                role: Permit.authorRole, admittedAt: Date(timeIntervalSince1970: 1_000),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)
        try writeThisDevicesRecord()
        try RegistryWriter.write(
            PersonRecord(
                person: identities.author.fingerprint, label: "Denver", ownName: "This Mac",
                role: Permit.authorRole, admittedAt: Date(timeIntervalSince1970: 2_000),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)
        return root
    }

    private func writeThisDevicesRecord() throws {
        try RegistryWriter.write(
            DeviceRecord(
                device: identities.author.fingerprint, name: "This Mac", kind: .mac,
                actors: Dictionary(uniqueKeysWithValues: DeviceActor.allCases.map {
                    ($0.rawValue, identities[$0].fingerprint)
                }),
                madeAt: Date(timeIntervalSince1970: 2_000)),
            signedBy: identities.author, in: projectURL)
    }

    private func narrow(
        _ subject: String, by root: DeviceIdentity, pieces: [String],
        mark: [String: PermitMark.StreamMark] = [:]
    ) throws {
        try RegistryWriter.write(
            PermitEvent(
                event: PermitEvent.mintID(subject: subject), kind: .scopeChanged,
                subject: subject, role: Permit.authorRole, scope: Permit.piecesScope,
                pieces: pieces, mark: mark,
                at: Date(timeIntervalSince1970: 3_000), by: root.fingerprint),
            signedBy: root, in: projectURL)
    }

    private func appliedSoFar() throws -> [String: PermitMark.StreamMark] {
        try OpLogStore.appliedPositions(
            ofDeviceIds: Set(identities.all.map(\.deviceId)),
            in: projectURL,
            trust: try TrustResolution.resolve(
                projectURL: projectURL, identities: identities)).streams
    }

    // MARK: - The door

    /// **An author of piece A may not change a figure created in piece B** —
    /// every mutator throws `FigureEditRefused` naming `.figure`, and nothing
    /// is appended. A figure of her own piece she may change (the control).
    func test_anAuthorOfPieceAMayNotChangeAFigureOfPieceB() async throws {
        let root = try makeForeignRoot()
        let store = try await ProjectStore.load(from: projectURL)
        let theirs = try await store.createFigure(kind: .table, name: "b_table", piece: Self.pieceB)
        let hers = try await store.createFigure(kind: .table, name: "a_table", piece: Self.pieceA)
        try narrow(identities.author.fingerprint, by: root, pieces: [Self.pieceA], mark: try appliedSoFar())

        let doc = try await load(theirs.id)
        XCTAssertEqual(doc.state.table.rows.count, 3, "precondition: the figure reads")
        let key = try firstKey(doc)
        let before = try streamBytes(of: theirs.id)
        let um = UndoManager()

        let presses: [(String, () async throws -> Void)] = [
            ("setCell", { try await doc.setCell(self.text("x"), at: key, undoManager: um) }),
            ("insertRow", { _ = try await doc.insertRow(after: nil, undoManager: um) }),
            ("insertColumn", { _ = try await doc.insertColumn(after: nil, undoManager: um) }),
            ("deleteRow", { try await doc.deleteRow(key.row) }),
            ("deleteColumn", { try await doc.deleteColumn(key.column) }),
            ("moveRow", { try await doc.moveRow(key.row, after: doc.state.table.rows.last, undoManager: um) }),
            ("moveColumn", { try await doc.moveColumn(key.column, after: doc.state.table.columns.last, undoManager: um) }),
            ("setHeaderRows", { try await doc.setHeaderRows(1, undoManager: um) }),
            ("setTotalRow", { try await doc.setTotalRow(true, undoManager: um) }),
            ("setColumnWidth", { try await doc.setColumnWidth(key.column, 80, undoManager: um) }),
        ]
        for (name, press) in presses {
            do {
                try await press()
                XCTFail("\(name) was not refused")
            } catch let refused as FigureEditRefused {
                XCTAssertEqual(refused.what, .figure, name)
                XCTAssertEqual(refused.site, name)
            } catch {
                XCTFail("\(name) threw \(error), not FigureEditRefused")
            }
        }
        XCTAssertEqual(try streamBytes(of: theirs.id), before, "no op was appended")
        XCTAssertEqual(doc.state.table.rows.count, 3)
        XCTAssertNil(doc.state.table[key])
        XCTAssertFalse(um.canUndo, "and nothing was registered")

        // Creating one there is refused at the same door.
        do {
            _ = try await store.createFigure(kind: .table, name: "more", piece: Self.pieceB)
            XCTFail("creating a figure in somebody else's piece was not refused")
        } catch let refused as FigureEditRefused {
            XCTAssertEqual(refused.what, .figure)
        }

        let own = try await load(hers.id)
        try await own.setCell(text("hers"), at: try firstKey(own), undoManager: nil)
        XCTAssertEqual(own.state.table[try firstKey(own)], text("hers"), "her own piece's figure she may change")
        await doc.close()
        await own.close()
    }

    /// **The partition sees `.figure`**: a cell written into a figure of piece
    /// A by a device whose author is narrowed to piece B is set aside on a book
    /// author's Mac; the same device's write into a figure of piece B applies.
    func test_aFigureLineFromAPieceBOnlyDeviceIsSetAside() async throws {
        // This device is the book's root.
        try writeThisDevicesRecord()
        try RegistryWriter.write(
            PersonRecord(
                person: identities.author.fingerprint, label: "Denver", ownName: "This Mac",
                role: Permit.authorRole, admittedAt: Date(timeIntervalSince1970: 1_000),
                admittedBy: identities.author.fingerprint),
            signedBy: identities.author, in: projectURL)
        // Sam's Mac, admitted and narrowed to piece B.
        let sam = LocalIdentities.softwareForTesting()
        try RegistryWriter.write(
            DeviceRecord(
                device: sam.author.fingerprint, name: "Sam's Mac", kind: .mac,
                actors: Dictionary(uniqueKeysWithValues: DeviceActor.allCases.map {
                    ($0.rawValue, sam[$0].fingerprint)
                }),
                madeAt: Date(timeIntervalSince1970: 2_000)),
            signedBy: sam.author, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: sam.author.fingerprint, label: "Sam", ownName: "Sam's Mac",
                role: Permit.authorRole, admittedAt: Date(timeIntervalSince1970: 2_000),
                admittedBy: identities.author.fingerprint),
            signedBy: identities.author, in: projectURL)
        try narrow(sam.author.fingerprint, by: identities.author, pieces: [Self.pieceB])

        let store = try await ProjectStore.load(from: projectURL)
        let ofA = try await store.createFigure(kind: .table, name: "of_a", piece: Self.pieceA)
        let ofB = try await store.createFigure(kind: .table, name: "of_b", piece: Self.pieceB)
        let readA = try await load(ofA.id)
        let readB = try await load(ofB.id)
        let keyA = try firstKey(readA)
        let keyB = try firstKey(readB)
        await readA.close()
        await readB.close()

        let samsStore = OpLogStore(
            projectURL: projectURL, identities: sam,
            state: OpLogDeviceState(fileURL: projectURL.appendingPathComponent("sam-state.json")))
        for (id, key) in [(ofA.id, keyA), (ofB.id, keyB)] {
            try await samsStore.append(Op(
                opId: ULID.generate(), docId: id, at: Date(), device: sam.author.deviceId,
                session: "sam", kind: .figureCellSet, changes: [],
                figure: FigureOpPayload(cell: key, next: text("sam"), prior: nil)))
            _ = try await samsStore.sealChain(docId: id)
        }

        let a = try await load(ofA.id)
        XCTAssertNil(a.state.table[keyA], "Sam's line in piece A's figure is set aside")
        XCTAssertGreaterThan(a.provenance?.quarantinedLines ?? 0, 0, "and counted as set aside")
        XCTAssertEqual(a.state.table.rows.count, 3, "the book author's own lines stand")

        let b = try await load(ofB.id)
        XCTAssertEqual(b.state.table[keyB], text("sam"), "control: in his own piece's figure it applies")
        await a.close()
        await b.close()
    }

    // MARK: - The window's door (ruling R-6a-8)

    /// A window on the book: this Mac roots the empty book at open.
    private func openWindow() async throws -> (DocumentStore, ProjectStore) {
        let store = try await DocumentStore.open(url: projectURL)
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (store, projectStore)
    }

    /// Sam is admitted as the author of piece B, so this root yields on B.
    private func samWritesPieceB(_ store: DocumentStore) async throws {
        let sam = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces([Self.pieceB])))
        await store.postureSettled()
    }

    /// **A figure follows its piece's window posture**: while the root yields
    /// piece B to Sam, B's text and B's figures are both refused — editing one
    /// and creating one; *Edit Anyway* on the piece lifts both.
    func test_aFigureInAYieldedPieceIsRefusedWhileItsTextIs_editAnywayLiftsBoth() async throws {
        let (store, projectStore) = try await openWindow()
        let record = try await projectStore.createFigure(kind: .table, name: "b_table", piece: Self.pieceB)
        try await samWritesPieceB(store)
        XCTAssertFalse(store.posture(forDocId: Self.pieceB).allows(.writeText),
                       "precondition: the piece's text is yielded")

        let doc = try await FigureDocument.load(
            figureId: record.id, projectURL: projectURL, actor: .author,
            session: "s", presenter: nil, documentStore: store)
        let key = try firstKey(doc)
        let before = try streamBytes(of: record.id)
        do {
            try await doc.setCell(text("x"), at: key, undoManager: nil)
            XCTFail("an edit in a yielded piece's figure was not refused")
        } catch let refused as FigureEditRefused {
            XCTAssertEqual(refused.what, .figure)
        }
        do {
            _ = try await projectStore.createFigure(kind: .table, name: "more", piece: Self.pieceB)
            XCTFail("creating a figure in a yielded piece was not refused")
        } catch is FigureEditRefused {}
        XCTAssertEqual(try streamBytes(of: record.id), before, "nothing was appended")
        XCTAssertEqual(projectStore.manifest.figures?.count, 1, "and nothing was created")

        store.overrideYield(docId: Self.pieceB)
        XCTAssertTrue(store.posture(forDocId: Self.pieceB).allows(.writeText),
                      "Edit Anyway lifts the piece's text")
        try await doc.setCell(text("x"), at: key, undoManager: nil)
        XCTAssertEqual(doc.state.table[key], text("x"), "and its figure")
        let more = try await projectStore.createFigure(kind: .table, name: "more", piece: Self.pieceB)
        XCTAssertEqual(more.piece, Self.pieceB, "and creating one there")
        await doc.close()
    }

    /// **An undo refused at the door declines out loud**: the edit was made
    /// while this Mac could write the figure; the yield began afterwards.
    func test_anUndoRefusedAtTheDoorDeclines() async throws {
        let (store, projectStore) = try await openWindow()
        let record = try await projectStore.createFigure(kind: .table, name: "b_table", piece: Self.pieceB)
        let doc = try await FigureDocument.load(
            figureId: record.id, projectURL: projectURL, actor: .author,
            session: "s", presenter: nil, documentStore: store)
        let key = try firstKey(doc)
        let um = UndoManager()
        try await doc.setCell(text("mine"), at: key, undoManager: um)
        try await samWritesPieceB(store)
        let count = try ops(of: record.id).count

        let said = await notices {
            um.undo()
            await doc.awaitPendingUndoWork()
        }
        XCTAssertEqual(said, ["Couldn't change the table — this Mac can no longer change this figure."])
        XCTAssertEqual(doc.state.table[key], text("mine"), "the edit stands")
        XCTAssertEqual(try ops(of: record.id).count, count, "nothing was appended")
        await doc.close()
    }

    // MARK: - Write order

    /// **The stream first, the record second**: an append that fails leaves no
    /// registry record — at most a stream nobody lists.
    func test_aFailedAppendLeavesNoRecord() async throws {
        struct Boom: Error {}
        let store = try await ProjectStore.load(from: projectURL)
        ProjectStore.beforeFigureAppendForTesting = { op in
            if op.kind == .figureStructure { throw Boom() }
        }
        do {
            _ = try await store.createFigure(kind: .table, name: "t", piece: nil)
            XCTFail("the injected append failure did not surface")
        } catch is Boom {}
        XCTAssertTrue(store.manifest.figures?.isEmpty ?? true, "no record in memory")
        let onDisk = try ProjectManifest.makeDecoder().decode(
            ProjectManifest.self,
            from: Data(contentsOf: projectURL.appendingPathComponent(ProjectManifest.fileName)))
        XCTAssertNil(onDisk.figures, "and none on disk")

        ProjectStore.beforeFigureAppendForTesting = nil
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        XCTAssertEqual(record.name, "t", "the name was never taken")
    }
}

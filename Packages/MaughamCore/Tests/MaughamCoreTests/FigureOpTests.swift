import XCTest
@testable import MaughamCore

/// Report plan 6a Task 1: figure ops ride the shared `Op` envelope with their
/// content in `Op.figure`, and nothing about an existing op's bytes moves.
final class FigureOpTests: XCTestCase {

    private func encoder() -> JSONEncoder {
        // `JSONLAppendStore.encode`'s own settings: the bytes on disk.
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        enc.outputFormatting = [.sortedKeys]
        return enc
    }

    private func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        return dec
    }

    private func line(_ op: Op) throws -> String {
        String(data: try encoder().encode(op), encoding: .utf8)!
    }

    private func figureOp(_ id: String, _ kind: OpKind, _ payload: FigureOpPayload) -> Op {
        Op(opId: id, docId: "fig-k3m9q2zt", at: Date(timeIntervalSince1970: 1_000),
           device: "macA", session: "s", kind: kind, changes: [], figure: payload)
    }

    private let r1 = RowID("r1aaaaaa"), r2 = RowID("r2bbbbbb")
    private let c1 = ColumnID("c1cccccc"), c2 = ColumnID("c2dddddd")

    /// One payload per shape the wire carries, with the kind it belongs to.
    private var everyShape: [(OpKind, FigureOpPayload)] {
        let key = CellKey(row: r1, column: c1)
        let cell = Cell(content: .value(.number(1234.5)), format: CellFormat(number: .general))
        let formula = Cell(content: .value(.text("Revenue")), alignment: .automatic)
        let pin = FigureResearchPin(
            research: "res-model", row: 8, column: 1, value: .number(42),
            sourceHash: "abc123", at: Date(timeIntervalSince1970: 2_000))
        let image = FigureImageRef(filename: "chart.png", contentHash: "h1")
        return [
            (.figureCreate, FigureOpPayload(kind: .table)),
            (.figureCreate, FigureOpPayload(kind: .image)),
            (.figureCreate, FigureOpPayload(kind: .table, source: FigureSource(
                researchItemId: "res-model", path: "research/model.csv", contentHash: "0123456789abcdef"))),
            (.figureParked, FigureOpPayload(parkedPath: "research/cashflow.csv", parkedHash: "h9")),
            (.figureParked, FigureOpPayload(parkedPath: "research/cashflow.csv", parkedHash: "h9",
                                            parkedItemId: "res-cash0001")),
            (.figureParked, FigureOpPayload(parkedPath: "research/cashflow.csv", parkedHash: "h9",
                                            parkedItemId: "res-cash0001",
                                            parkedFrontier: ["macA": "01A", "macB": "01B"])),
            (.figureResumed, FigureOpPayload()),
            (.figureCellSet, FigureOpPayload(cell: key, next: cell, prior: nil)),
            (.figureCellSet, FigureOpPayload(cell: key, next: nil, prior: formula)),
            (.figureCellSet, FigureOpPayload(cell: key, next: cell, prior: formula)),
            (.figureStructure, FigureOpPayload(structure: .insertRow(r2, after: r1))),
            (.figureStructure, FigureOpPayload(structure: .insertRow(r2, after: nil))),
            (.figureStructure, FigureOpPayload(structure: .insertColumn(c2, after: c1))),
            (.figureStructure, FigureOpPayload(structure: .insertColumn(c2, after: nil))),
            (.figureStructure, FigureOpPayload(structure: .deleteRow(r1))),
            (.figureStructure, FigureOpPayload(structure: .deleteColumn(c1))),
            (.figureStructure, FigureOpPayload(structure: .deleteRow(r1), removed: FigureRemovedSlice(
                cells: [.init(at: c1.raw, cell: cell, pins: [pin]), .init(at: c2.raw, cell: formula)]))),
            (.figureStructure, FigureOpPayload(structure: .deleteColumn(c1), removed: FigureRemovedSlice(width: 80))),
            (.figureStructure, FigureOpPayload(structure: .reviveRow(r1), removed: FigureRemovedSlice())),
            (.figureStructure, FigureOpPayload(structure: .reviveColumn(c1), removed: FigureRemovedSlice(
                cells: [.init(at: r2.raw, pins: [pin])], width: 64.5))),
            (.figureStructure, FigureOpPayload(structure: .moveRow(r1, after: r2, priorAfter: nil))),
            (.figureStructure, FigureOpPayload(structure: .moveRow(r1, after: nil, priorAfter: r2))),
            (.figureStructure, FigureOpPayload(structure: .moveColumn(c1, after: c2, priorAfter: nil))),
            (.figureSettings, FigureOpPayload(settings: .headerRows(1, prior: 0))),
            (.figureSettings, FigureOpPayload(settings: .totalRow(true, prior: false))),
            (.figureSettings, FigureOpPayload(settings: .columnWidth(c1, 80, prior: nil))),
            (.figureSettings, FigureOpPayload(settings: .columnWidth(c1, nil, prior: 64.5))),
            (.figureImageSet, FigureOpPayload(image: image)),
            (.figureImageSet, FigureOpPayload(image: image,
                                              priorImage: FigureImageRef(filename: "old.png", contentHash: "h0"))),
            (.figurePinSet, FigureOpPayload(cell: key, pin: pin)),
            (.figurePinClear, FigureOpPayload(cell: key)),
            (.figurePinClear, FigureOpPayload(cell: key, pin: pin)),
        ]
    }

    // MARK: - Round trips

    func test_everyPayloadShapeRoundTripsThroughTheEnvelope() throws {
        for (index, (kind, payload)) in everyShape.enumerated() {
            let op = figureOp("01F\(index)", kind, payload)
            let decoded = try decoder().decode(Op.self, from: Data(try line(op).utf8))
            XCTAssertEqual(decoded, op, "shape \(index) (\(kind))")
            XCTAssertEqual(decoded.figure, payload, "shape \(index) (\(kind))")
            XCTAssertTrue(FigureOpPayload.validate(kind: kind, payload: payload), "shape \(index) (\(kind))")
        }
    }

    func test_theKindsRawValuesAreTheirSnakeCaseNames() {
        XCTAssertEqual(FigureOpPayload.kinds.map(\.rawValue), [
            "figure_create", "figure_parked", "figure_resumed", "figure_cell_set",
            "figure_structure", "figure_settings", "figure_image_set",
            "figure_pin_set", "figure_pin_clear",
        ])
    }

    /// The wire words are flat and readable; a change of spelling here is a
    /// change every figure op log on disk silently loses.
    func test_theStructureAndSettingsWireShapesArePinned() throws {
        let enc = encoder()
        let move = String(data: try enc.encode(FigureStructureChange.moveRow(r1, after: r2, priorAfter: nil)),
                          encoding: .utf8)
        XCTAssertEqual(move, #"{"after":"r2bbbbbb","change":"move_row","row":"r1aaaaaa"}"#)
        let width = String(data: try enc.encode(FigureSettingsChange.columnWidth(c1, 80, prior: nil)),
                           encoding: .utf8)
        XCTAssertEqual(width, #"{"column":"c1cccccc","setting":"column_width","width":80}"#)
        let payload = String(data: try enc.encode(FigureOpPayload(
            image: FigureImageRef(filename: "a.png", contentHash: "h"),
            priorImage: nil, parkedPath: "p", parkedHash: "q")), encoding: .utf8)
        XCTAssertEqual(payload,
                       #"{"image":{"content_hash":"h","filename":"a.png"},"parked_hash":"q","parked_path":"p"}"#)
        // Report plan 6b Task 7: the Research item a park wrote, schema 10.
        let parked = String(data: try enc.encode(FigureOpPayload(
            parkedPath: "research/cash.csv", parkedHash: "q", parkedItemId: "res-1")), encoding: .utf8)
        XCTAssertEqual(parked,
                       #"{"parked_hash":"q","parked_item_id":"res-1","parked_path":"research\/cash.csv"}"#)
        // Report plan 6b Task 8: what the parker had read, per device stream.
        let frontier = String(data: try enc.encode(FigureOpPayload(
            parkedPath: "p", parkedHash: "q", parkedFrontier: ["macA": "01A"])), encoding: .utf8)
        XCTAssertEqual(frontier, #"{"parked_frontier":{"macA":"01A"},"parked_hash":"q","parked_path":"p"}"#)
        var state = FigureState()
        FigureDeriver.fold(Op(opId: "01", docId: "fig-k3m9q2zt", at: Date(timeIntervalSince1970: 0),
                              device: "macA", session: "s", kind: .figureParked, changes: [],
                              figure: FigureOpPayload(parkedPath: "p", parkedHash: "q",
                                                      parkedFrontier: ["macA": "01A"])), into: &state)
        XCTAssertEqual(state.parked?.frontier, ["macA": "01A"], "the fold keeps it")
    }

    /// **The revive words and the removed slice** (report plan 6b Task 4,
    /// rulings P-1/P-2, schema 10): pinned like the words before them.
    func test_theReviveWordsAndTheRemovedSliceArePinned() throws {
        let enc = encoder()
        XCTAssertEqual(String(data: try enc.encode(FigureStructureChange.reviveRow(r1)), encoding: .utf8),
                       #"{"change":"revive_row","row":"r1aaaaaa"}"#)
        XCTAssertEqual(String(data: try enc.encode(FigureStructureChange.reviveColumn(c1)), encoding: .utf8),
                       #"{"change":"revive_column","column":"c1cccccc"}"#)
        let delete = String(data: try enc.encode(FigureOpPayload(
            structure: .deleteColumn(c1),
            removed: FigureRemovedSlice(cells: [.init(at: r2.raw, cell: Cell(content: .value(.number(1))))], width: 80))),
            encoding: .utf8)
        XCTAssertEqual(delete,
            #"{"removed":{"cells":[{"at":"r2bbbbbb","cell":{"alignment":"automatic","content":{"value":{"_0":{"number":{"_0":1}}}},"format":{"negatives":"minus","number":{"general":{}},"zeroAsDash":false}}}],"width":80},"structure":{"change":"delete_column","column":"c1cccccc"}}"#)
        XCTAssertEqual(String(data: try enc.encode(FigureOpPayload(structure: .deleteRow(r1))), encoding: .utf8),
                       #"{"structure":{"change":"delete_row","row":"r1aaaaaa"}}"#,
                       "a delete without a slice carries no removed key")
        XCTAssertFalse(FigureOpPayload.validate(kind: .figureStructure, payload: FigureOpPayload(structure: .reviveRow(r1))),
                       "a revive carries a slice")
    }

    /// Report plan 6b Task 9 (ruling P-8, schema 10): a pin set carries the
    /// pin it replaced under `prior_pin`; a first pin carries none.
    func test_thePriorPinWireWordIsPinned() throws {
        let pin = FigureResearchPin(research: "res-a", row: 1, column: 2, value: .number(3), sourceHash: "h",
                                    at: Date(timeIntervalSince1970: 0))
        let key = CellKey(row: r1, column: c1)
        func keys(_ p: FigureOpPayload) throws -> [String] {
            let object = try JSONSerialization.jsonObject(with: try encoder().encode(p)) as? [String: Any]
            return (object?.keys).map { $0.sorted() } ?? []
        }
        XCTAssertEqual(try keys(FigureOpPayload(cell: key, pin: pin, priorPin: pin)), ["cell", "pin", "prior_pin"])
        XCTAssertEqual(try keys(FigureOpPayload(cell: key, pin: pin)), ["cell", "pin"])
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        let back = try dec.decode(
            FigureOpPayload.self, from: try encoder().encode(FigureOpPayload(cell: key, pin: pin, priorPin: pin)))
        XCTAssertEqual(back.priorPin, pin)
    }

    /// Report plan 6b Task 6 (spec §4.1, schema 10): a figure made from a
    /// Research item records where it came from on its `figureCreate`, and the
    /// deriver keeps it.
    func test_theSourceWireShapeIsPinned_andTheDeriverKeepsIt() throws {
        let source = FigureSource(researchItemId: "res-model", path: "research/model.csv",
                                  contentHash: "0123456789abcdef")
        XCTAssertEqual(String(data: try encoder().encode(FigureOpPayload(kind: .table, source: source)),
                              encoding: .utf8),
            #"{"kind":"table","source":{"content_hash":"0123456789abcdef","path":"research\/model.csv","research_item_id":"res-model"}}"#)
        XCTAssertEqual(String(data: try encoder().encode(FigureOpPayload(kind: .table)), encoding: .utf8),
                       #"{"kind":"table"}"#, "a figure made in the book carries no source key")
        let state = FigureDeriver.derive([figureOp("01S1", .figureCreate, FigureOpPayload(kind: .table, source: source))])
        XCTAssertEqual(state.source, source)
        XCTAssertNil(FigureDeriver.derive([figureOp("01S2", .figureCreate, FigureOpPayload(kind: .table))]).source)
    }

    // MARK: - Existing bytes

    /// **Golden.** An existing op's line is byte-for-byte what it was before
    /// `Op.figure` existed: a nil figure is absent, not `null`.
    func test_aPreExistingOpsBytesAreUnchanged() throws {
        let op = Op(opId: "01A", docId: "doc-0f0f0f0f", at: Date(timeIntervalSince1970: 0),
                    device: "macA", session: "s", kind: .typingBurst,
                    changes: [.init(paragraphId: "ab2c", prior: "Hel", next: "Hello")],
                    sequence: ["ab2c"], provenance: .init(sessionId: "s1"))
        let golden = #"{"at":"1970-01-01T00:00:00.000Z","changes":[{"next":"Hello","paragraph_id":"ab2c","prior":"Hel"}],"device":"macA","doc_id":"doc-0f0f0f0f","kind":"typing_burst","op_id":"01A","provenance":{"session_id":"s1"},"sequence":["ab2c"],"session":"s"}"#
        XCTAssertEqual(try line(op), golden)
        XCTAssertEqual(try decoder().decode(Op.self, from: Data(golden.utf8)), op)
        XCTAssertNil(op.withReplacedOpId("01B").figure)
    }

    func test_withReplacedOpIdKeepsTheFigure() {
        let op = figureOp("01A", .figureCreate, FigureOpPayload(kind: .table))
        let copy = op.withReplacedOpId("01B")
        XCTAssertEqual(copy.opId, "01B")
        XCTAssertEqual(copy.figure, op.figure)
        XCTAssertEqual(copy.kind, .figureCreate)
    }

    func test_theCellAnchorProvenanceFieldsHaveTheirWireNames() throws {
        let p = Op.Provenance(figureRowId: "r1", figureRowEndId: "r2",
                              figureColId: "c1", figureColEndId: "c2")
        let json = String(data: try encoder().encode(p), encoding: .utf8)
        XCTAssertEqual(json,
                       #"{"figure_col_end_id":"c2","figure_col_id":"c1","figure_row_end_id":"r2","figure_row_id":"r1"}"#)
        XCTAssertEqual(try decoder().decode(Op.Provenance.self, from: Data(json!.utf8)), p)
    }

    // MARK: - Forward tolerance

    /// A kind from a later build still decodes, as `.unknown`, figure payload
    /// and all — the existing tolerance holds with the new field.
    func test_anUnknownFutureKindStillDecodesAsUnknown() throws {
        let raw = #"{"at":"1970-01-01T00:00:00.000Z","changes":[],"device":"macA","doc_id":"fig-k3m9q2zt","figure":{"kind":"table"},"kind":"figure_chart_set","op_id":"01Z","session":"s"}"#
        let op = try decoder().decode(Op.self, from: Data(raw.utf8))
        XCTAssertEqual(op.kind, .unknown)
        XCTAssertEqual(op.figure, FigureOpPayload(kind: .table))
        XCTAssertEqual(Op.kind(ofLine: Data(raw.utf8)), .unknown)
    }

    /// **A later build's FIGURE kind decodes too** (ruling R-6a-3): kept as
    /// `.unknown`, re-encoded as the same word, and never a valid create.
    func test_anUnknownFigureKindDecodesAndRoundTrips() throws {
        let raw = #"{"at":"1970-01-01T00:00:00.000Z","changes":[],"device":"macA","doc_id":"fig-k3m9q2zt","figure":{"kind":"chart"},"kind":"figure_create","op_id":"01Z","session":"s"}"#
        let op = try decoder().decode(Op.self, from: Data(raw.utf8))
        XCTAssertEqual(op.kind, .figureCreate)
        XCTAssertEqual(op.figure?.kind, .unknown("chart"))
        XCTAssertFalse(FigureOpPayload.validate(kind: .figureCreate, payload: try XCTUnwrap(op.figure)),
                       "a create of a kind this build cannot read is not a valid create")
        XCTAssertEqual(String(data: try JSONEncoder().encode(FigureKind.unknown("chart")), encoding: .utf8),
                       #""chart""#)
        XCTAssertEqual(FigureKind(rawValue: "table"), .table)
        XCTAssertEqual(FigureKind(rawValue: "image"), .image)
        XCTAssertEqual(FigureKind.known, [.table, .image])
    }

    // MARK: - The classifiers

    func test_noFigureKindIsManuscriptTextToTheDeriverOrALoadEmission() {
        for kind in FigureOpPayload.kinds {
            XCTAssertFalse(Deriver.appliesToManuscript(kind), "\(kind)")
            XCTAssertFalse(Permit.isALoadEmission(.op(kind)), "\(kind)")
            XCTAssertEqual(Permit.group(of: kind), .manuscriptText, "\(kind) — ruling D-c")
        }
    }

    // MARK: - Integrity and backup

    func test_integrityChecksPassAStreamOfFigureOps() {
        let ops = everyShape.enumerated().map { figureOp("01F\($0.offset)", $0.element.0, $0.element.1) }
        XCTAssertEqual(IntegrityChecks.invalidParagraphIds(inOps: ops), [])
    }

    @MainActor
    func test_backupSignatureCountsFigureOpIds() throws {
        let proj = TestTemp.root.appendingPathComponent("figsig-\(UUID().uuidString)")
        let ops = proj.appendingPathComponent(".maugham/ops")
        try FileManager.default.createDirectory(at: ops, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: proj) }
        let file = ops.appendingPathComponent("fig-k3m9q2zt.macA.jsonl")
        let first = figureOp("01A", .figureCreate, FigureOpPayload(kind: .table))
        try (try line(first) + "\n").write(to: file, atomically: true, encoding: .utf8)
        let before = BackupSignature.compute(projectURL: proj)

        let second = figureOp("01B", .figureCellSet, FigureOpPayload(
            cell: CellKey(row: r1, column: c1), next: Cell(content: .value(.number(1)))))
        try (try line(first) + "\n" + line(second) + "\n").write(to: file, atomically: true, encoding: .utf8)
        let after = BackupSignature.compute(projectURL: proj)
        XCTAssertNotEqual(before, after, "a figure op's id is counted, so the edit is a change")

        // ...and the count is by id: rewriting the same op ids changes nothing.
        try (try line(first) + "\n" + line(second) + "\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(BackupSignature.compute(projectURL: proj), after)
    }

    // MARK: - Validation

    func test_validateRejectsAKindMissingItsRequiredFields() {
        XCTAssertFalse(FigureOpPayload.validate(kind: .figureCellSet, payload: FigureOpPayload()))
        XCTAssertFalse(FigureOpPayload.validate(
            kind: .figureCellSet, payload: FigureOpPayload(next: Cell(content: .value(.number(1))))))
        XCTAssertFalse(FigureOpPayload.validate(kind: .figureCreate, payload: FigureOpPayload()))
        XCTAssertFalse(FigureOpPayload.validate(kind: .figureParked, payload: FigureOpPayload(parkedPath: "p")))
        XCTAssertFalse(FigureOpPayload.validate(kind: .figureStructure, payload: FigureOpPayload()))
        XCTAssertFalse(FigureOpPayload.validate(kind: .figureSettings, payload: FigureOpPayload()))
        XCTAssertFalse(FigureOpPayload.validate(kind: .figureImageSet, payload: FigureOpPayload()))
        XCTAssertFalse(FigureOpPayload.validate(
            kind: .figurePinSet, payload: FigureOpPayload(cell: CellKey(row: r1, column: c1))))
        XCTAssertFalse(FigureOpPayload.validate(kind: .figurePinClear, payload: FigureOpPayload()))
        XCTAssertTrue(FigureOpPayload.validate(kind: .figureResumed, payload: FigureOpPayload()))
        XCTAssertFalse(FigureOpPayload.validate(kind: .typingBurst, payload: FigureOpPayload(kind: .table)),
                       "a non-figure kind never carries a figure payload")
    }

    /// A picture's file name is joined onto `figures/` when the picture is
    /// replaced, and it arrives in ops from other devices: one that could
    /// leave the folder makes the op invalid, so it is never folded and never
    /// written to (security review, path traversal).
    func test_aPictureNameThatCouldLeaveTheFiguresFolderMakesTheOpInvalid() {
        let good = FigureImageRef(filename: "chart.png", contentHash: "h")
        XCTAssertTrue(FigureOpPayload.validate(kind: .figureImageSet, payload: FigureOpPayload(image: good)))
        for bad in ["../notes.md", "../../x.png", "a/b.png", "a\\b.png", "..", ".", ".hidden.png", "", "x\0.png"] {
            let ref = FigureImageRef(filename: bad, contentHash: "h")
            XCTAssertFalse(ref.isAPlainFileName, bad)
            XCTAssertFalse(FigureOpPayload.validate(kind: .figureImageSet, payload: FigureOpPayload(image: ref)), bad)
            XCTAssertFalse(FigureOpPayload.validate(
                kind: .figureImageSet, payload: FigureOpPayload(image: good, priorImage: ref)), bad)
            XCTAssertFalse(FigureOpPayload.validate(
                kind: .figureCreate, payload: FigureOpPayload(kind: .image, image: ref)), bad)
        }
    }
}

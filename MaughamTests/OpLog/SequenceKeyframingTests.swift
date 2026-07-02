import XCTest
@testable import Maugham
@testable import MaughamCore

/// M1 — sequence keyframing (ADR 0016 / growth spec §4). Burst ops carry
/// `sequence` only when ordering changed, at the keyframe floor, or on the
/// first burst after load; otherwise nil (deriver carries forward).
@MainActor
final class SequenceKeyframingTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyframing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    /// Real .md + Bootstrap-minted 4-char anchors (tripwire 8): every test
    /// here crosses the .md ↔ op-log boundary via Document.load.
    private func makeDoc(
        paragraphs: [String] = ["First paragraph.", "Second paragraph.", "Third paragraph."]
    ) async throws -> Document {
        let url = projectURL.appendingPathComponent("manuscript/doc.md")
        try paragraphs.joined(separator: "\n\n")
            .write(to: url, atomically: true, encoding: .utf8)
        return try await Document.load(
            url: url, device: "test-mac", session: "s1", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
    }

    private func lastBurst(of doc: Document) -> Op? {
        doc.opLogSnapshot.last { $0.kind == .typingBurst }
    }

    // T1 + spec §4.1 rule 3 (first burst after load anchors the session).
    func test_textOnlyBurst_omitsSequence() async throws {
        let doc = try await makeDoc()
        let id = doc.sequence[0]

        // First burst after load: carries sequence (rule 3).
        doc.setParagraph(id: id, text: "First paragraph, edited.")
        try await doc.flushBurstNow()
        XCTAssertNotNil(lastBurst(of: doc)?.sequence,
                        "first burst after load must anchor the session")

        // Second, text-only burst: ordering unchanged → nil.
        doc.setParagraph(id: id, text: "First paragraph, edited twice.")
        try await doc.flushBurstNow()
        XCTAssertNil(lastBurst(of: doc)?.sequence,
                     "text-only burst must omit the redundant sequence")
        await doc.close()
    }

    // T2 — every ordering mutator re-arms sequence capture.
    func test_orderingChange_capturesSequence() async throws {
        let doc = try await makeDoc()

        // Drain the first-burst keyframe so each case below isolates its mutator.
        doc.setParagraph(id: doc.sequence[0], text: "Edited 0.")
        try await doc.flushBurstNow()

        // insertParagraph
        _ = doc.insertParagraph(after: doc.sequence[0], text: "Inserted.")
        try await doc.flushBurstNow()
        XCTAssertEqual(lastBurst(of: doc)?.sequence, doc.sequence,
                       "insertParagraph must put sequence on the next burst")

        // deleteParagraph
        doc.deleteParagraph(id: doc.sequence[1])
        try await doc.flushBurstNow()
        XCTAssertEqual(lastBurst(of: doc)?.sequence, doc.sequence,
                       "deleteParagraph must put sequence on the next burst")

        // reorder — emits no op itself; needs a pending change to flush with.
        doc.reorder(sequence: doc.sequence.reversed())
        doc.setParagraph(id: doc.sequence[0], text: "Edited after reorder.")
        try await doc.flushBurstNow()
        XCTAssertEqual(lastBurst(of: doc)?.sequence, doc.sequence,
                       "reorder must put sequence on the next burst")

        // setFullText with a paragraph split (sequenceChanged path).
        let split = doc.displayText
            .replacingOccurrences(of: "Edited after reorder.",
                                  with: "Edited after reorder.\n\nBrand new split paragraph.")
        doc.setFullText(split)
        try await doc.flushBurstNow()
        XCTAssertEqual(lastBurst(of: doc)?.sequence, doc.sequence,
                       "setFullText with sequenceChanged must capture sequence")
        await doc.close()
    }

    // T6 — keyframe floor: the (interval+1)th sequence-less burst keyframes.
    func test_keyframeFloor_emitsEveryNth() async throws {
        let doc = try await makeDoc()
        let id = doc.sequence[0]

        // Burst 1: rule-3 keyframe.
        doc.setParagraph(id: id, text: "v0")
        try await doc.flushBurstNow()

        // Bursts 2..(interval+1): text-only → nil.
        for i in 1...Document.sequenceKeyframeInterval {
            doc.setParagraph(id: id, text: "v\(i)")
            try await doc.flushBurstNow()
            XCTAssertNil(lastBurst(of: doc)?.sequence, "burst \(i) within the floor window")
        }

        // Next burst crosses the floor → keyframe.
        doc.setParagraph(id: id, text: "floor")
        try await doc.flushBurstNow()
        XCTAssertNotNil(lastBurst(of: doc)?.sequence,
                        "the floor keyframe must fire after \(Document.sequenceKeyframeInterval) sequence-less bursts")
        await doc.close()
    }

    /// Reconstruct the pre-M1 "full capture" twin of a keyframed log.
    private func fullCaptureTwin(of ops: [Op]) -> [Op] {
        var last: [String]? = nil
        return ops.sorted { $0.opId < $1.opId }.map { op in
            if let s = op.sequence { last = s; return op }
            guard op.kind == .typingBurst, let carried = last else { return op }
            return Op(opId: op.opId, docId: op.docId, at: op.at,
                      device: op.device, session: op.session, kind: op.kind,
                      changes: op.changes, sequence: carried,
                      provenance: op.provenance)
        }
    }

    // T3 — parity with full capture, including rewind state at EVERY cursor.
    func test_keyframedLog_derivesIdenticalToFullCapture() async throws {
        let doc = try await makeDoc()
        // Edit script mixing text-only bursts and ordering changes.
        doc.setParagraph(id: doc.sequence[0], text: "alpha edit")
        try await doc.flushBurstNow()
        doc.setParagraph(id: doc.sequence[1], text: "beta edit")
        try await doc.flushBurstNow()                       // nil-sequence burst
        _ = doc.insertParagraph(after: doc.sequence[1], text: "gamma inserted")
        try await doc.flushBurstNow()                       // keyframe
        doc.setParagraph(id: doc.sequence[2], text: "gamma edited")
        try await doc.flushBurstNow()                       // nil-sequence burst
        doc.deleteParagraph(id: doc.sequence[0])
        try await doc.flushBurstNow()                       // keyframe
        doc.setParagraph(id: doc.sequence[0], text: "delta edit")
        try await doc.flushBurstNow()                       // nil-sequence burst

        // Snapshot BEFORE close: close() husks the in-memory mirror
        // (opLogSnapshot goes empty on a closed doc by design).
        let keyframed = doc.opLogSnapshot.sorted { $0.opId < $1.opId }
        await doc.close()

        XCTAssertTrue(keyframed.contains { $0.kind == .typingBurst && $0.sequence == nil },
                      "script must actually produce keyframed (nil) bursts")
        let full = fullCaptureTwin(of: keyframed)

        // Full-log parity.
        XCTAssertEqual(Deriver.derive(ops: keyframed), Deriver.derive(ops: full))

        // Rewind parity at EVERY cursor (derive(ops:upTo:) folds the prefix).
        for op in keyframed {
            let cursor = RewindCursor.atOp(opId: op.opId, at: op.at)
            XCTAssertEqual(
                Deriver.derive(ops: keyframed, upTo: cursor),
                Deriver.derive(ops: full, upTo: cursor),
                "state-at-cursor must be exact at op \(op.opId)")
        }
    }

    // T4 — cross-device improvement, pinned so nobody "fixes" it back:
    // B reorders; A's LATER text-only burst is sequence-nil → B's order survives.
    // (Pre-M1, A's burst stamped a stale full sequence and reverted B.)
    func test_concurrentReorder_survivesTextOnlyBurstMerge() async throws {
        let store = OpLogStore(projectURL: projectURL)
        let docId = "doc-t4"
        func op(_ opId: String, device: String, kind: OpKind,
                changes: [Op.ParagraphChange] = [], sequence: [String]? = nil) -> Op {
            Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
               device: device, session: "s", kind: kind,
               changes: changes, sequence: sequence)
        }
        // opIds are deliberately lexicographically ordered ("01-boot" <
        // "02-reorder" < "03-text"): the deriver/merge sorts by opId string.
        // Shared history: bootstrap [p1, p2].
        try await store.append(op("01-boot", device: "deviceB", kind: .bootstrap,
            changes: [.init(paragraphId: "p1", prior: nil, next: "one"),
                      .init(paragraphId: "p2", prior: nil, next: "two")],
            sequence: ["p1", "p2"]))
        // B reorders → [p2, p1] (ordering change always carries sequence).
        try await store.append(op("02-reorder", device: "deviceB", kind: .typingBurst,
            changes: [], sequence: ["p2", "p1"]))
        // A types text-only with a LATER opId — keyframed → sequence nil.
        try await store.append(op("03-text", device: "deviceA", kind: .typingBurst,
            changes: [.init(paragraphId: "p1", prior: "one", next: "one edited")],
            sequence: nil))

        let derived = Deriver.derive(ops: try await store.load(docId: docId))
        XCTAssertEqual(derived.sequence, ["p2", "p1"],
                       "B's reorder must survive A's later text-only burst")
        XCTAssertEqual(derived.paragraphs["p1"], "one edited",
                       "A's text edit must still apply")
    }

    // T5 — spec §4.4: a fresh keyframed log always derives a non-empty
    // sequence, so nothing forces the doc to render empty on load.
    func test_freshLog_neverTriggersEmptySequenceRecovery() async throws {
        let doc = try await makeDoc()
        let id = doc.sequence[0]
        doc.setParagraph(id: id, text: "First, edited.")
        try await doc.flushBurstNow()
        doc.setParagraph(id: id, text: "First, edited again.")
        try await doc.flushBurstNow()                       // nil-sequence burst
        await doc.close()

        // The op-log alone (no .md help) must carry a non-empty sequence:
        // op #1 is the sequence-bearing bootstrap op.
        let ops = try await OpLogStore(projectURL: projectURL).load(docId: doc.docId)
        let derived = Deriver.derive(ops: ops)
        XCTAssertFalse(derived.sequence.isEmpty,
                       "keyframed fresh log must never derive an empty sequence")
        XCTAssertFalse(derived.paragraphs.isEmpty)

        // And reconcile() must treat that derived state as canonical: no orphan
        // paragraphs to drop, so sequence passes through unchanged.
        let reconciled = Document.reconcile(derived: derived)
        XCTAssertEqual(reconciled.sequence, derived.sequence,
                       "reconcile must not rewrite a keyframed log's ordering")

        // End-to-end: a fresh load shows the edited text.
        let reloaded = try await Document.load(
            url: doc.url, device: "test-mac", session: "s2", presenter: nil)
        XCTAssertTrue(reloaded.displayText.contains("First, edited again."))
        await reloaded.close()
    }

    // T7 — spec §4.2: on append failure `_orderingDirty` survives; the next
    // successful flush still carries sequence. Uses the existing injection
    // seam OpLogStore.appendFailureForTesting — do not add another.
    func test_appendFailure_preservesOrderingDirty() async throws {
        struct Boom: Error {}
        let doc = try await makeDoc()
        // Drain the rule-3 keyframe.
        doc.setParagraph(id: doc.sequence[0], text: "warmup")
        try await doc.flushBurstNow()

        // Ordering change, then an injected append failure.
        _ = doc.insertParagraph(after: doc.sequence[0], text: "inserted")
        doc.opStore.appendFailureForTesting = Boom()
        do {
            try await doc.flushBurstNow()
            XCTFail("flush should rethrow the injected append failure")
        } catch is Boom {
            // expected: the injected failure propagates
        }

        // Recovery: the next successful flush must still carry the sequence.
        doc.opStore.appendFailureForTesting = nil
        try await doc.flushBurstNow()
        XCTAssertEqual(lastBurst(of: doc)?.sequence, doc.sequence,
                       "ordering signal must survive an append failure")
        await doc.close()
    }
}

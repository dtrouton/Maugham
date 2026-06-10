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
}

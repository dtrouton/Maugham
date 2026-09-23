import Foundation
import XCTest
@testable import MaughamCore

/// **What a held line IS, in the writer's terms** (P3b smoke find F2).
///
/// Kit's one paragraph of prose was announced as *1 note waiting* on the
/// admission sheet and *1 note is waiting in a piece no one has claimed yet* on
/// History. `HeldLines.Waiting` counts prose by paragraph and everything else
/// as notes, by asking `Deriver.appliesToManuscript` (tripwire 44).
final class HeldLinesWaitingTests: XCTestCase {

    private let kit = "kitkey"
    private let sam = "samkey"

    private func line(
        _ kind: OpKind, _ changes: [(String, String)] = [], heldBy device: String,
        opId: String = UUID().uuidString
    ) throws -> OpLogChain.Line {
        let op = Op(
            opId: opId, docId: "doc-1", at: Date(timeIntervalSince1970: 100),
            device: device, session: "s", kind: kind,
            changes: changes.map { Op.ParagraphChange(paragraphId: $0.0, prior: nil, next: $0.1) })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        return OpLogChain.Line(
            bytes: try encoder.encode(op), kind: .op, state: .pending(device: device))
    }

    func test_aHeldParagraphIsProseAndNotANote() throws {
        let waiting = HeldLines.Waiting.byDevice(of: [
            try line(.typingBurst, [("p1ab", "The rain came in sideways.")], heldBy: kit),
        ])[kit]

        XCTAssertEqual(waiting?.paragraphs, 1)
        XCTAssertEqual(waiting?.notes, 0)
        XCTAssertEqual(waiting?.peek, "The rain came in sideways.")
        XCTAssertEqual(waiting?.phrase?.text, "1 paragraph")
        XCTAssertEqual(waiting?.phrase?.isPlural, false)
    }

    func test_oneParagraphTypedInThreeBurstsIsOneParagraphAndPeeksAtItsLastWords() throws {
        let waiting = HeldLines.Waiting.byDevice(of: [
            try line(.typingBurst, [("p1ab", "The rain")], heldBy: kit),
            try line(.typingBurst, [("p1ab", "The rain came in")], heldBy: kit),
            try line(.typingBurst, [("p1ab", "The rain came in sideways.")], heldBy: kit),
            try line(.typingBurst, [("p2cd", "Second.")], heldBy: kit),
        ])[kit]

        XCTAssertEqual(waiting?.paragraphs, 2)
        XCTAssertEqual(waiting?.prose, 4)
        XCTAssertEqual(waiting?.peek, "The rain came in sideways.",
                       "the FIRST paragraph held, as it LAST reads")
        XCTAssertEqual(waiting?.phrase?.text, "2 paragraphs")
    }

    func test_annotationsAreNotesAndAreCountedApartFromProse() throws {
        let waiting = HeldLines.Waiting.byDevice(of: [
            try line(.claudeComment, heldBy: sam),
            try line(.annotationEdit, heldBy: sam),
            try line(.typingBurst, [("p1ab", "Words.")], heldBy: sam),
        ])[sam]

        XCTAssertEqual(waiting?.notes, 2)
        XCTAssertEqual(waiting?.paragraphs, 1)
        XCTAssertEqual(waiting?.phrase?.text, "1 paragraph and 2 notes")
        XCTAssertEqual(waiting?.phrase?.isPlural, true)
    }

    func test_onlyHeldOpLinesAreCountedAndEachUnderItsOwnHolder() throws {
        var applied = try line(.typingBurst, [("p9zz", "Applied.")], heldBy: kit)
        applied = OpLogChain.Line(bytes: applied.bytes, kind: .op, state: .verified)
        let seal = OpLogChain.Line(
            bytes: Data("{\"seal\":1}".utf8), kind: .seal, state: .pending(device: kit))
        let answer = HeldLines.Waiting.byDevice(of: [
            applied, seal,
            try line(.typingBurst, [("p1ab", "Kit's.")], heldBy: kit),
            try line(.claudeQuery, heldBy: sam),
        ])

        XCTAssertEqual(answer[kit]?.paragraphIds, ["p1ab"],
                       "an applied line and a seal are not waiting")
        XCTAssertEqual(answer[kit]?.notes, 0)
        XCTAssertEqual(answer[sam]?.notes, 1)
        XCTAssertEqual(answer[sam]?.paragraphs, 0)
    }

    func test_aProseOpNamingNoParagraphIsStillSaid() {
        let waiting = HeldLines.Waiting(prose: 1)
        XCTAssertEqual(waiting.phrase?.text, "1 change")
        XCTAssertNil(HeldLines.Waiting().phrase)
    }

    func test_twoFilesMergeIntoOneDescription() {
        let a = HeldLines.Waiting(paragraphIds: ["p1ab"], prose: 1, notes: 1, peek: "First")
        let b = HeldLines.Waiting(paragraphIds: ["p1ab", "p2cd"], prose: 2, peek: "Later")
        let merged = a.merged(with: b)
        XCTAssertEqual(merged.paragraphs, 2)
        XCTAssertEqual(merged.notes, 1)
        XCTAssertEqual(merged.peek, "First")
    }

    // MARK: - The sentences say it

    /// **F2 on History**: the §4.5 banner about Kit's paragraph.
    func test_thePieceStartSentenceSaysParagraphForProse() throws {
        let sentence = try XCTUnwrap(HeldLines.sentence(
            .permitPending(person: kit, startedAPiece: true), notes: 1,
            what: HeldLines.Waiting(paragraphIds: ["p1ab"], prose: 1), named: "Kit"))

        XCTAssertTrue(sentence.hasPrefix("1 paragraph from Kit is waiting in a piece"),
                      sentence)
        XCTAssertFalse(sentence.contains("note"), sentence)
    }

    func test_everyArmTakesTheDescriptionAndAgreesInNumber() throws {
        let both = HeldLines.Waiting(paragraphIds: ["p1ab"], prose: 1, notes: 1)
        for holder: HeldLines.Holder in [
            .stranger(fingerprint: kit),
            .permitPending(person: kit, startedAPiece: false),
            .unsigned(stream: "author-beef"),
        ] {
            let sentence = try XCTUnwrap(
                HeldLines.sentence(holder, notes: 2, what: both, named: "Kit"))
            XCTAssertTrue(sentence.contains("1 paragraph and 1 note"), sentence)
            XCTAssertTrue(sentence.contains(" are waiting"), sentence)
        }
    }

    func test_withNoDescriptionTheSentenceIsWhatItAlwaysWas() throws {
        let sentence = try XCTUnwrap(HeldLines.sentence(
            .stranger(fingerprint: kit), notes: 3, named: "Kit’s iPhone"))
        XCTAssertEqual(sentence, "3 notes from Kit’s iPhone are waiting for admission.")
    }

    // MARK: - The load counts it

    /// The provenance a load produces carries the description beside the
    /// count, from the same lines, and the project-wide union merges it.
    func test_theProvenanceUnionMergesDescriptions() {
        let one = FileProvenance(
            name: "a", pending: 1, pendingByDevice: [kit: 1],
            pendingWaitingByDevice: [kit: HeldLines.Waiting(paragraphIds: ["p1ab"], prose: 1)])
        let two = FileProvenance(
            name: "b", pending: 1, pendingByDevice: [kit: 1],
            pendingWaitingByDevice: [kit: HeldLines.Waiting(notes: 1)])
        let union = OpLogProvenance(files: [one, two]).pendingWaitingByDevice[kit]
        XCTAssertEqual(union?.phrase?.text, "1 paragraph and 1 note")
    }
}

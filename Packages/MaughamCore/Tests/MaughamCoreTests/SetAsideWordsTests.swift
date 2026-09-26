import XCTest
@testable import MaughamCore

/// **The words a set-aside line carried** (signed op log P3b Task 8, spec §7.4).
///
/// A `.lines` record is forensics the writer can read and never history the
/// book applies. §7.4's one way back is the writer's own hand: the paragraphs
/// the refusal took away come back as CAPTURES, so the question this suite
/// pins is which archived lines hold manuscript words at all, and what those
/// words and their author were.
///
/// **The manuscript list is asked, never restated** (tripwire 44): the decode
/// is `PermitPartition.writtenOp` and the classification is
/// `Deriver.appliesToManuscript`, so a kind a later build starts folding into
/// the draft becomes recoverable here on the same day it becomes manuscript
/// text anywhere else.
final class SetAsideWordsTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = TestTemp.root
            .appendingPathComponent("setaside-words-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        tmp = nil
        super.tearDown()
    }

    // MARK: - Which lines hold words

    func test_aTypingBurstsParagraphsAreTheWordsItTookAway() throws {
        let words = OpLogQuarantine.recoverableWords(inLines: [
            opLine(kind: "typing_burst", device: "author-abcdef0123456789",
                   changes: [("p1ab", "The sea was flat that morning."),
                             ("p2cd", "Nobody was awake but the gulls.")])
        ])

        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words.map(\.text),
                       ["The sea was flat that morning.",
                        "Nobody was awake but the gulls."])
        XCTAssertEqual(words.map(\.paragraphId), ["p1ab", "p2cd"])
        XCTAssertEqual(Set(words.map(\.device)), ["author-abcdef0123456789"])
        XCTAssertEqual(Set(words.map(\.opId)).count, 1,
                       "one op, however many paragraphs it moved")
    }

    /// **The other direction, and the one the door turns on.** A record made
    /// entirely of dispositions, tasks and annotations took no words away, so
    /// there is nothing to send anywhere.
    func test_aRecordOfDispositionsAndTasksAndNotesHoldsNoWords() throws {
        let words = OpLogQuarantine.recoverableWords(inLines: [
            opLine(kind: "annotation_triage", device: "author-abcdef0123456789",
                   changes: [("p1ab", "not manuscript text")]),
            opLine(kind: "task_create", device: "author-abcdef0123456789",
                   changes: [("p2cd", "nor this")]),
            opLine(kind: "claude_comment", device: "assistant-abcdef0123456789",
                   changes: [("p3ef", "nor this")]),
        ])

        XCTAssertTrue(words.isEmpty, "got \(words)")
    }

    /// A seal is a signature, not a change — and it is recognised in
    /// `OpLogChain` alone (tripwire 37), never by a second reader here.
    func test_aSealCarriesNoWords() throws {
        XCTAssertTrue(OpLogQuarantine.recoverableWords(inLines: [seal()]).isEmpty)
    }

    /// A line that does not parse, or carries no `kind`, is nobody's to
    /// recover — the same answer `PermitPartition.writtenOp` gives about it.
    /// A translation record is the production case: `TranslationRecord` has no
    /// `kind` at all.
    func test_aLineThatIsNotAnOpCarriesNoWords() throws {
        let translation = #"{"op_id":"01","paragraph_id":"p1ab","language":"es","#
            + #""text":"La mar.","source_hash":"h","verbatim":false,"#
            + #""at":"2026-09-20T10:00:00.000Z"}"#

        XCTAssertTrue(OpLogQuarantine.recoverableWords(inLines: [
            Data("not json at all".utf8),
            Data(translation.utf8),
        ]).isEmpty)
    }

    /// **An inbox row carries a `kind` and it is still not words** (P3b Task 8
    /// fix round 1's census). `InboxEntry.Kind` is `text`/`image`/`audio`, so
    /// `Op.kind(ofLine:)` answers `.unknown` rather than nil — and `.unknown`
    /// is inert through `Deriver.appliesToManuscript` (ADR 0015), which is why
    /// the capture streams offer no door. Stated as a test because the two
    /// reasons a stream offers nothing — no `kind`, and a `kind` this table
    /// calls unknown — are different, and only one of them was pinned.
    func test_anInboxRowsOwnKindIsNotAManuscriptKind() throws {
        let row = #"{"id":"01M2RMZS8S08J1MKA7CPTFK4MS","created_at":"#
            + #""2026-09-20T10:00:00.000Z","device_id":"author-abcdef0123456789","#
            + #""kind":"text","inline_text":"A captured sentence.","#
            + #""transcription_state":"none","status":"new"}"#

        XCTAssertEqual(
            PermitPartition.writtenOp(Data(row.utf8)), .op(.unknown),
            "premise: the row's own kind reads as an unknown op kind")
        XCTAssertFalse(Deriver.appliesToManuscript(.unknown))
        XCTAssertTrue(
            OpLogQuarantine.recoverableWords(inLines: [Data(row.utf8)]).isEmpty)
    }

    /// A deletion took no words away — `next` is empty, and a capture holding
    /// nothing is a row the writer has to throw away by hand.
    func test_aDeletedParagraphIsNotRecoverable() throws {
        XCTAssertTrue(OpLogQuarantine.recoverableWords(inLines: [
            opLine(kind: "typing_burst", device: "author-abcdef0123456789",
                   changes: [("p1ab", ""), ("p2cd", "   ")])
        ]).isEmpty)
    }

    /// The same op reaching the archive twice is one change — `setAsideChanges`
    /// says so about the count, and the words must say it too, or a second
    /// press would file the paragraph twice.
    func test_theSameOpInTwoRecordsIsOneSetOfWords() throws {
        let line = opLine(kind: "typing_burst", device: "author-abcdef0123456789",
                          changes: [("p1ab", "Once only.")])

        XCTAssertEqual(
            OpLogQuarantine.recoverableWords(inLines: [line, line]).count, 1)
    }

    // MARK: - Over a record on disk

    func test_aRecordsOwnArchiveIsRead() throws {
        let record = try XCTUnwrap(OpLogQuarantine.setAsideLines(
            [opLine(kind: "typing_burst", device: "translator-abcdef0123456789",
                    changes: [("p1ab", "La mar estaba lisa.")]),
             seal()],
            from: tmp.appendingPathComponent(".maugham/ops/doc-1.macb.jsonl"),
            docId: "doc-1",
            reason: "written by the translation pipeline, which writes only translations",
            in: tmp))

        let words = OpLogQuarantine.recoverableWords(ofRecord: record, in: tmp)
        XCTAssertEqual(words.map(\.text), ["La mar estaba lisa."])
        XCTAssertEqual(words.first?.device, "translator-abcdef0123456789")
    }

    /// A `.file` record is a whole op log that would not read, not a run of
    /// refused lines — there is nothing here to recover from it.
    func test_aWholeFileRecordOffersNoWords() throws {
        let src = tmp.appendingPathComponent(".maugham/ops/doc-1.maca.jsonl")
        try Data("{\"op_id\":\"x\"}\n".utf8).write(to: src)
        let record = try MainActor.assumeIsolated {
            try OpLogQuarantine.quarantine(
                fileURL: src, docId: "doc-1", reason: "permission denied",
                in: tmp, isDatalessStub: { _ in false })
        }

        XCTAssertTrue(OpLogQuarantine.recoverableWords(ofRecord: record, in: tmp).isEmpty)
    }

    // MARK: - Who wrote the lines in a record

    func test_aRecordNamesEveryDeviceItsLinesCarry() throws {
        let record = try XCTUnwrap(OpLogQuarantine.setAsideLines(
            [opLine(kind: "typing_burst", device: "author-abcdef0123456789",
                    changes: [("p1ab", "Hers.")]),
             opLine(kind: "annotation_triage", device: "assistant-abcdef0123456789",
                    changes: [("p2cd", "not words, but still a writer")]),
             seal()],
            from: tmp.appendingPathComponent(".maugham/ops/doc-1.macb.jsonl"),
            docId: "doc-1", reason: "written after this device was retired",
            in: tmp))

        XCTAssertEqual(
            OpLogQuarantine.writers(ofRecord: record, in: tmp),
            ["author-abcdef0123456789", "assistant-abcdef0123456789"],
            "every op counts, not only the ones holding words — a record of "
            + "dispositions alone still shows a sentence about somebody")
    }

    // MARK: - C16: the reason a record is shown under

    /// A second, harsher revocation of the same bytes files no new record
    /// (content-addressed), so the frozen sentence goes on describing a choice
    /// the writer has replaced.
    func test_aRevocationsSentenceFollowsTheWritersLatestChoice() {
        let gentle = "written after this device's access was withdrawn"
        let harsh = "set aside with everything this device wrote"

        XCTAssertEqual(OpLogQuarantine.reason(gentle, nowKeepsNothing: true), harsh)
        XCTAssertEqual(OpLogQuarantine.reason(harsh, nowKeepsNothing: false), gentle)
        XCTAssertEqual(OpLogQuarantine.reason(gentle, nowKeepsNothing: nil), gentle,
                       "nobody this register knows wrote it")
    }

    /// **The other direction.** A cause is a fact about what the walk met, and
    /// a revocation since is no reason to revise it.
    func test_noOtherCauseIsEverReDerived() {
        for frozen in [
            "written by something that is not Maugham",
            "the history's chain is broken",
            "written after this device was retired",
            "written under another claimant's copy of this book",
            "written into the manuscript by a device that may not write it here",
        ] {
            XCTAssertEqual(
                OpLogQuarantine.reason(frozen, nowKeepsNothing: true), frozen)
            XCTAssertEqual(
                OpLogQuarantine.reason(frozen, nowKeepsNothing: false), frozen)
        }
    }

    /// The two sentences are the op log's own, asked of `quarantineReason`
    /// rather than spelled here — so a change to either moves both together.
    func test_theTwoSentencesAreTheOpLogsOwn() {
        XCTAssertEqual(
            OpLogQuarantine.reason(
                JSONLAppendStore<Op>.quarantineReason(
                    .afterRevocation(person: "p", keptNothing: false)),
                nowKeepsNothing: true),
            JSONLAppendStore<Op>.quarantineReason(
                .afterRevocation(person: "p", keptNothing: true)))
    }

    // MARK: - Fixtures

    private func opLine(
        kind: String, device: String, changes: [(String, String)]
    ) -> Data {
        let changeJSON = changes.map {
            #"{"paragraph_id":"\#($0.0)","next":"\#($0.1)"}"#
        }.joined(separator: ",")
        let opId = "01M2RMZS8S08J1MKA7CPTF" + String(
            abs(kind.hashValue &+ changes.count).description.prefix(4))
        let json = #"{"op_id":"\#(opId)","doc_id":"doc-1","#
            + #""at":"2026-09-20T10:00:00.000Z","device":"\#(device)","#
            + #""session":"s1","kind":"\#(kind)","changes":[\#(changeJSON)]}"#
        return Data(json.utf8)
    }

    private func seal() -> Data {
        Data(#"{"seal":{"at":"2026-09-17T21:39:58.365Z","head":"abc","key":"k","sig":"s"}}"#.utf8)
    }
}

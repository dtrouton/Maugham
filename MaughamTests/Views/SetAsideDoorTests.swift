import XCTest
import MaughamCore
@testable import Maugham

/// **The way back in** (signed op log P3b Task 8, spec §7.4).
///
/// A set-aside record never softens: nothing here applies a line, nothing
/// re-admits a key, the archives are not touched. What is decided is which
/// records took WORDS out of the writer's draft, because those words can come
/// back through the writer's own hand as captures.
///
/// Pinned windowlessly on the pure model (tripwire 33): which rows carry the
/// control is the row's own field, so even *is the door offered* is decided
/// here rather than by looking at a window. What the press DOES is
/// `InboxStoreRecoveredWordsTests`'.
@MainActor
final class SetAsideDoorTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    // MARK: - Which records offer it

    func test_aRecordHoldingManuscriptTextOffersTheWordsBack() throws {
        let project = try makeProject()
        let record = try lines([
            burst(device: "author-abcdef0123456789",
                  paragraphs: [("p1ab", "The tide went out and stayed out."),
                               ("p2cd", "She counted the boats twice.")])
        ], in: project)

        let rows = SetAsideDoor.rows(records: [record], in: project, sent: [])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].words, 2)
        XCTAssertTrue(rows[0].offersTheDoor)
        XCTAssertTrue(rows[0].doorHelp.contains("2 set-aside paragraphs"))
        XCTAssertTrue(
            rows[0].doorHelp.contains("Nothing is applied"),
            "the promise is stated before the press — got \(rows[0].doorHelp)")
        XCTAssertNil(rows[0].sentNote, "nothing has been sent yet")
    }

    /// **The other direction.** A refusal that took no words away has nothing
    /// to give back, and a button promising some would be a lie about the
    /// evidence.
    func test_aRecordOfDispositionsAndTasksOffersNothing() throws {
        let project = try makeProject()
        let record = try lines([
            op(kind: "annotation_triage", device: "author-abcdef0123456789",
               paragraphs: [("p1ab", "a decision on a note")]),
            op(kind: "task_create", device: "maugham-abcdef0123456789",
               paragraphs: [("p2cd", "a task")]),
        ], in: project)

        let rows = SetAsideDoor.rows(records: [record], in: project, sent: [])

        XCTAssertEqual(rows[0].words, 0)
        XCTAssertFalse(rows[0].offersTheDoor,
                       "no words were taken away, so there is no door")
    }

    /// **Offered once.** A second press would file every paragraph a second
    /// time; the row stays and says what the first press did.
    func test_aRecordThisMacHasAlreadySentOffersNoSecondDoor() throws {
        let project = try makeProject()
        let record = try lines([
            burst(device: "author-abcdef0123456789",
                  paragraphs: [("p1ab", "Once only.")])
        ], in: project)
        let name = SetAsideAcknowledgement.name(for: record, in: project)

        let rows = SetAsideDoor.rows(
            records: [record], in: project, sent: [name])

        XCTAssertEqual(rows[0].words, 1, "the evidence is unchanged")
        XCTAssertTrue(rows[0].sent)
        XCTAssertFalse(rows[0].offersTheDoor)
        XCTAssertEqual(rows[0].sentNote, "1 paragraph sent to the Inbox",
                       "the row says what the press did rather than going quiet")
    }

    /// A `.file` record is a whole op log that would not read — Retry's
    /// subject, not this one's.
    func test_aWholeFileRecordOffersNoDoor() throws {
        let project = try makeProject()
        let src = project.appendingPathComponent(".maugham/ops/doc-1.maca.jsonl")
        try Data("{\"op_id\":\"x\"}\n".utf8).write(to: src)
        let record = try OpLogQuarantine.quarantine(
            fileURL: src, docId: "doc-1", reason: "permission denied",
            in: project, isDatalessStub: { _ in false })

        XCTAssertFalse(
            SetAsideDoor.rows(records: [record], in: project, sent: [])[0]
                .offersTheDoor)
    }

    // MARK: - The words a press would send

    func test_theCapturesAreTheParagraphsAndWhoWroteThem() throws {
        let project = try makeProject()
        let record = try lines([
            burst(device: "assistant-abcdef0123456789",
                  paragraphs: [("p1ab", "A sentence it should not have written.")])
        ], in: project)

        let captures = SetAsideDoor.captures(
            forRecord: record, in: project,
            attribution: { "from \($0.device)" })

        XCTAssertEqual(captures, [SetAsideDoor.Capture(
            text: "A sentence it should not have written.",
            attribution: "from assistant-abcdef0123456789")])
    }

    // MARK: - C16: the sentence

    func test_aRevocationsSentenceFollowsTheWritersLatestChoice() {
        let gentle = "written after this device's access was withdrawn"
        let harsh = "set aside with everything this device wrote"

        XCTAssertEqual(
            SetAsideDoor.sentence(frozen: gentle, nowKeepsNothing: true), harsh,
            "the writer has since set aside everything that device wrote")
        XCTAssertEqual(
            SetAsideDoor.sentence(frozen: harsh, nowKeepsNothing: false), gentle)
        XCTAssertEqual(
            SetAsideDoor.sentence(frozen: gentle, nowKeepsNothing: nil), gentle,
            "nobody this book knows wrote it; the frozen words stand")
    }

    /// **The other direction, and the one that keeps the evidence honest.** A
    /// broken chain is not re-read as a revocation because somebody has since
    /// been revoked — the cause is a fact about what the walk met.
    func test_aBrokenChainIsNeverReDerivedAsARevocation() {
        let chain = "written by something that is not Maugham"
        for now in [true, false] {
            XCTAssertEqual(
                SetAsideDoor.sentence(frozen: chain, nowKeepsNothing: now), chain)
        }
        let retired = "written after this device was retired"
        XCTAssertEqual(
            SetAsideDoor.sentence(frozen: retired, nowKeepsNothing: true), retired)
    }

    // MARK: - Who a recovered capture is from

    func test_theAssistantIsNamedAndNeverGivenAProductName() {
        let line = SetAsideDoor.attribution(
            forDeviceId: "assistant-abcdef0123456789",
            registry: Registry(), table: TrustResolution.keyless(mine: .current))

        XCTAssertTrue(line.contains("the assistant"), "got \(line)")
        XCTAssertFalse(line.lowercased().contains("claude"),
                       "the AI actor is never given a product name — got \(line)")
        XCTAssertTrue(line.contains("this Mac"),
                      "no chain and no record: the honest word is this Mac")
    }

    func test_eachOfTheFourWritersIsNamedAsItself() {
        let registry = Registry()
        let table = TrustResolution.keyless(mine: .current)
        func line(_ actor: String) -> String {
            SetAsideDoor.attribution(
                forDeviceId: "\(actor)-abcdef0123456789",
                registry: registry, table: table)
        }

        XCTAssertFalse(line("author").contains(" on "),
                       "the writer's own hand names no second party")
        XCTAssertTrue(line("translator").contains("translation pipeline"))
        XCTAssertTrue(line("maugham").contains("housekeeping"))
        XCTAssertNotEqual(line("author"), line("assistant"),
                          "four writers, four sentences")
    }

    // MARK: - Where the memory lives

    /// Per device, additive, and no key at all where the door has never been
    /// used — so a `ui-state.json` written before this task is the file it
    /// always was.
    func test_theSentMemoryIsAdditiveAndWritesNoKeyWhenEmpty() throws {
        let encoded = try JSONEncoder().encode(UIState.empty)
        XCTAssertFalse(
            String(decoding: encoded, as: UTF8.self)
                .contains("sentSetAsideRecords"))

        let older = try JSONDecoder().decode(
            UIState.self, from: Data("{\"schemaVersion\":1}".utf8))
        XCTAssertTrue(older.sentSetAsideRecords.isEmpty,
                      "absent means the door has not been used, and it is "
                      + "offered once")

        var state = UIState.empty
        state.sentSetAsideRecords = ["a.lines", "b.lines"]
        let back = try JSONDecoder().decode(
            UIState.self, from: try JSONEncoder().encode(state))
        XCTAssertEqual(back.sentSetAsideRecords, ["a.lines", "b.lines"])
        XCTAssertTrue(back.acknowledgedSetAsideRecords.isEmpty,
                      "the two memories are two facts: sending is not "
                      + "acknowledging")
    }

    func test_theStoresVerbUnionsAndNeverForgets() async throws {
        let temp = try TempDirectory()
        let url = try await ProjectFactory.createNovelProject(
            named: "SetasideDoor", in: temp.url)
        let store = try await DocumentStore.open(url: url)

        XCTAssertTrue(store.uiState.sentSetAsideRecords.isEmpty)

        store.recordSetAsideSentToInbox(["a.lines"])
        store.recordSetAsideSentToInbox(["b.lines"])
        XCTAssertEqual(store.uiState.sentSetAsideRecords, ["a.lines", "b.lines"],
                       "the second press adds; it does not replace")

        store.recordSetAsideSentToInbox([])
        XCTAssertEqual(store.uiState.sentSetAsideRecords, ["a.lines", "b.lines"],
                       "an empty press is a no-op, not a clear")
        XCTAssertTrue(store.uiState.acknowledgedSetAsideRecords.isEmpty,
                      "and sending has not quietly acknowledged anything")
    }

    // MARK: - Drawn, never pressed (tripwire 33)

    func test_theDisclosureDrawsTheDoorAndTheHistoryPanePressesIt() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()      // Views
                .deletingLastPathComponent()      // MaughamTests
                .deletingLastPathComponent()      // repo root
                .appendingPathComponent("Maugham/Views/HistoryPane.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains("Button(\"Send to Inbox\") { onSend(row) }"),
                      "the control is drawn")
        XCTAssertTrue(source.contains("if row.offersTheDoor {"),
                      "…and only where the model says there is a door")
        XCTAssertTrue(
            source.contains("SetAsideRecordsDisclosure(\n                        rows: setAsideRows, onSend: sendSetAsideToInbox)"),
            "…and the press reaches the pane's one verb")
        XCTAssertTrue(source.contains("documentStore.recordSetAsideSentToInbox([row.name])"),
                      "…which remembers it, so the door is not offered twice")
    }

    // MARK: - Fixtures

    private func makeProject() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("setaside-door-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func lines(
        _ lines: [Data], in project: URL,
        reason: String = "written after this device was retired"
    ) throws -> QuarantineRecord {
        try XCTUnwrap(OpLogQuarantine.setAsideLines(
            lines,
            from: project.appendingPathComponent(".maugham/ops/doc-1.macb.jsonl"),
            docId: "doc-1", reason: reason, in: project))
    }

    private func burst(
        device: String, paragraphs: [(String, String)]
    ) -> Data {
        op(kind: "typing_burst", device: device, paragraphs: paragraphs)
    }

    private func op(
        kind: String, device: String, paragraphs: [(String, String)]
    ) -> Data {
        let changes = paragraphs.map {
            #"{"paragraph_id":"\#($0.0)","next":"\#($0.1)"}"#
        }.joined(separator: ",")
        let opId = "01M2RMZS8S08J1MKA7CPTF" + String(
            (abs(kind.hashValue &+ device.hashValue) % 9999).description
                .padding(toLength: 4, withPad: "0", startingAt: 0))
        let json = #"{"op_id":"\#(opId)","doc_id":"doc-1","#
            + #""at":"2026-09-20T10:00:00.000Z","device":"\#(device)","#
            + #""session":"s1","kind":"\#(kind)","changes":[\#(changes)]}"#
        return Data(json.utf8)
    }
}

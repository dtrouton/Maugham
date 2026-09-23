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

    // MARK: - C16's input: which revocation the writer actually pressed

    /// **The harsh press, and only it, is `keptNothing`** (fix round 2, I2).
    ///
    /// Both arms, because the two presses are told apart by one field and
    /// getting it wrong is silent in the direction that misreports the writer's
    /// own choice back to them.
    func test_onlyARevocationThatRecordsNoMarkKeepsNothing() throws {
        let project = try makeProject()
        // The id's hex run must be a PREFIX of the key it claims, or nothing
        // in the register joins the two (`DeviceIdentity.actor(ofDeviceId:
        // signingWith:)`) — which is what makes the device string a claim this
        // table checks rather than a name it believes.
        let key = String(repeating: "c3", count: 32)
        let device = "author-" + String(key.prefix(16))
        let record = try lines([
            burst(device: device, paragraphs: [("p1ab", "Hers.")])
        ], in: project, reason: "written after this device's access was withdrawn")

        // The GENTLE press over a person this book had applied nothing of: a
        // real mark, written so the two presses stay tellable apart.
        XCTAssertEqual(
            SetAsideDoor.keepsNothingNow(
                record, in: project,
                table: revoked(device: device, key: key,
                               mark: RevocationScope.nothingAppliedMark)),
            false,
            "the writer pressed the gentle button; History must not redraw it "
            + "as the harsh one")

        // The HARSH press: no mark at all.
        XCTAssertEqual(
            SetAsideDoor.keepsNothingNow(
                record, in: project,
                table: revoked(device: device, key: key, mark: nil)),
            true)

        // And a person in good standing corrects nothing.
        XCTAssertNil(SetAsideDoor.keepsNothingNow(
            record, in: project,
            table: revoked(device: device, key: key, mark: "01", standing: true)))
    }

    /// The two sentences that follow, so the arms above are connected to what
    /// the writer reads.
    func test_theGentlePressKeepsItsOwnSentence() throws {
        let project = try makeProject()
        let key = String(repeating: "c3", count: 32)
        let device = "author-" + String(key.prefix(16))
        let gentle = "written after this device's access was withdrawn"
        let record = try lines([
            burst(device: device, paragraphs: [("p1ab", "Hers.")])
        ], in: project, reason: gentle)
        let table = revoked(device: device, key: key,
                            mark: RevocationScope.nothingAppliedMark)

        XCTAssertEqual(
            SetAsideDoor.changesByReason(
                records: [record], in: project,
                nowKeepsNothing: {
                    SetAsideDoor.keepsNothingNow($0, in: project, table: table)
                }),
            [gentle: 1])
    }

    /// A trust table in which `device` resolves to a person this root revoked.
    private func revoked(
        device: String, key: String, mark: String?, standing: Bool = false
    ) -> TrustTable {
        let root = String(repeating: "b4", count: 32)
        let person = key
        let registry = Registry(
            devices: [
                DeviceRecord(
                    device: person, name: "Their Mac", kind: .mac,
                    actors: [DeviceActor.author.rawValue: key],
                    madeAt: Date(timeIntervalSince1970: 1)),
                DeviceRecord(
                    device: root, name: "Root", kind: .mac,
                    actors: [DeviceActor.author.rawValue: root],
                    madeAt: Date(timeIntervalSince1970: 1)),
            ],
            people: [
                PersonRecord(
                    person: root, label: "Denver", ownName: "Root",
                    admittedAt: Date(timeIntervalSince1970: 1), admittedBy: root),
                PersonRecord(
                    person: person, label: "Sam", ownName: "Their Mac",
                    admittedAt: Date(timeIntervalSince1970: 2), admittedBy: root,
                    revokedAt: standing ? nil : Date(timeIntervalSince1970: 3),
                    revokedBy: standing ? nil : root,
                    highestOpIdSeen: mark),
            ])
        return TrustTable.resolve(
            registry: registry, mine: .current, joinedRoot: root)
    }

    // MARK: - Who a recovered capture is from

    /// **A chain break names nobody** (fix round 2, M6). Those bytes were
    /// refused because nothing in the file vouches for them, so the `device`
    /// string inside them is a word whatever-wrote-them chose — and the writer
    /// deciding whether to keep the paragraph must not be shown a byline the
    /// book cannot stand behind.
    func test_aChainBreaksCapturesAreAttributedToNobody() throws {
        let project = try makeProject()
        let device = "author-abcdef0123456789"
        let registry = Registry()
        let table = TrustResolution.keyless(mine: .current)

        for broken in ["written by something that is not Maugham",
                       "the history's chain is broken"] {
            let record = try lines([
                burst(device: device, paragraphs: [("p1ab", "\(broken).")])
            ], in: project, reason: broken)
            let line = SetAsideDoor.attribution(
                forRecord: record, deviceId: device,
                registry: registry, table: table)

            XCTAssertEqual(line, SetAsideDoor.unattributable, broken)
            XCTAssertFalse(line.contains("abcdef"),
                           "the device the bytes NAME is never read out")
        }
    }

    /// **The other direction.** Every other cause names a device whose lines
    /// these really are, and the capture says so.
    func test_everyOtherCauseKeepsItsByline() throws {
        let project = try makeProject()
        let device = "assistant-abcdef0123456789"

        for cause in [
            "written after this device was retired",
            "written after this device's access was withdrawn",
            "set aside with everything this device wrote",
            "written under another claimant's copy of this book",
            "written by the assistant, which never changes the manuscript",
        ] {
            let record = try lines([
                burst(device: device, paragraphs: [("p1ab", "\(cause).")])
            ], in: project, reason: cause)
            let line = SetAsideDoor.attribution(
                forRecord: record, deviceId: device,
                registry: Registry(),
                table: TrustResolution.keyless(mine: .current))

            XCTAssertNotEqual(line, SetAsideDoor.unattributable, cause)
            XCTAssertTrue(line.contains("the assistant"), cause)
        }
    }

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

    // MARK: - The other door: a held span nothing signs (fix round 1)

    private func heldProvenance(
        _ counts: [String: Int], strangers: Set<String> = []
    ) -> OpLogProvenance {
        OpLogProvenance(files: [FileProvenance(
            name: "doc.author-a.jsonl",
            pending: counts.values.reduce(0, +),
            pendingByDevice: counts,
            pendingStrangerDevices: strangers)])
    }

    private var unsignedHolder: String {
        HeldLines.unsignedHolder(forStreamKey: "doc-1.ghost", deviceSlug: "ghost")
    }

    private var personHolder: String { String(repeating: "a2", count: 32) }

    func test_anUnsignedHolderWithWaitingWordsOffersTheDoor() throws {
        let rows = HistoryPane.heldLineRows(
            provenance: heldProvenance([unsignedHolder: 2]),
            startedAPiece: [], names: [:],
            words: [unsignedHolder: 3], sent: [], docId: "doc-1")

        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].offersTheDoor)
        XCTAssertEqual(rows[0].words, 3)
        XCTAssertTrue(rows[0].doorHelp.contains("3 waiting paragraphs"))
        XCTAssertTrue(rows[0].doorHelp.contains("Nothing is applied"))
        XCTAssertTrue(rows[0].sentence.contains("Inbox"),
                      "premise: the sentence already names the way in")
    }

    /// **The door is the unsigned arm's alone.** An admitted person's held line
    /// is let in by a later build or by the writer's own answer about a piece,
    /// and both of those APPLY it — copying it out as a capture beside them
    /// would be a second, worse way in for words that have a real one.
    func test_aPermitPendingHolderIsOfferedNoDoorEvenWithWordsInHand() throws {
        let rows = HistoryPane.heldLineRows(
            provenance: heldProvenance([personHolder: 2]),
            startedAPiece: [], names: [personHolder: "Sam"],
            words: [personHolder: 4], sent: [], docId: "doc-1")

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].words, 0)
        XCTAssertFalse(rows[0].offersTheDoor)
    }

    /// A re-read that found no prose — or that would not read at all — leaves
    /// the holder out of the map, and no door is offered rather than one that
    /// promises a capture nobody can make.
    func test_aReReadThatFoundNothingOffersNoDoor() throws {
        let rows = HistoryPane.heldLineRows(
            provenance: heldProvenance([unsignedHolder: 2]),
            startedAPiece: [], names: [:], words: [:], sent: [], docId: "doc-1")

        XCTAssertEqual(rows.count, 1, "the sentence is still said")
        XCTAssertEqual(rows[0].words, 0)
        XCTAssertFalse(rows[0].offersTheDoor)
        XCTAssertNil(rows[0].sentNote)
    }

    /// Offered once, and the memory is per DOCUMENT as well as per holder — a
    /// holder is a whole stream, and a stream runs through every chapter it
    /// wrote in.
    func test_aSpanThisMacHasSentOffersNoSecondDoorAndOnlyForThatDocument() throws {
        let sent: Set<String> = [
            SetAsideDoor.heldKey(docId: "doc-1", holder: unsignedHolder)
        ]
        func rows(_ docId: String) -> [SetAsideDoor.HeldRow] {
            HistoryPane.heldLineRows(
                provenance: heldProvenance([unsignedHolder: 2]),
                startedAPiece: [], names: [:],
                words: [unsignedHolder: 3], sent: sent, docId: docId)
        }

        XCTAssertFalse(rows("doc-1")[0].offersTheDoor)
        XCTAssertEqual(rows("doc-1")[0].sentNote, "3 paragraphs sent to the Inbox")
        XCTAssertTrue(rows("doc-2")[0].offersTheDoor,
                      "another chapter's waiting words are another door")
    }

    /// A stranger is left to the admission sentence, which has a control of its
    /// own — saying it twice would put two counts about one device on one
    /// screen.
    func test_aStrangerIsStillNoRowAtAll() throws {
        let stranger = String(repeating: "f1", count: 32)
        XCTAssertTrue(HistoryPane.heldLineRows(
            provenance: heldProvenance([stranger: 3], strangers: [stranger]),
            startedAPiece: [], names: [:], words: [stranger: 9],
            sent: [], docId: "doc-1").isEmpty)
    }

    /// The sentences are unchanged: `heldLineNotices` is these rows' own.
    func test_theNoticesAreTheRowsSentences() throws {
        let provenance = heldProvenance([unsignedHolder: 2, personHolder: 1])
        XCTAssertEqual(
            HistoryPane.heldLineNotices(
                provenance: provenance, startedAPiece: [],
                names: [personHolder: "Sam"]),
            HistoryPane.heldLineRows(
                provenance: provenance, startedAPiece: [],
                names: [personHolder: "Sam"]).map(\.sentence))
    }

    /// **`HeldLines`' own words, and never a missing part.** Telling a writer
    /// their other machine has *no key* describes what it lacks; what is true
    /// of it is that nothing it writes is signed.
    func test_aRecoveredHeldParagraphIsAttributedInHeldLinesOwnWords() {
        let line = SetAsideDoor.unsignedAttribution

        XCTAssertTrue(line.contains(HeldLines.unsignedWriter),
                      "one phrase, shared — got \(line)")
        for banned in ["enclave", "no key", "unsigned:", "claude"] {
            XCTAssertFalse(line.localizedCaseInsensitiveContains(banned),
                           "\(banned) in \(line)")
        }
        XCTAssertTrue(
            HeldLines.sentence(.unsigned(stream: "ghost"), notes: 1)?
                .contains(HeldLines.unsignedWriter) ?? false,
            "…and the sentence the row draws uses the same phrase")
    }

    /// The press over a book holding nothing sends nothing, writes no memory,
    /// and raises nothing.
    func test_aPressWithNothingWaitingSendsNothingAndRemembersNothing() async throws {
        let temp = try TempDirectory()
        let url = try await ProjectFactory.createNovelProject(
            named: "HeldDoor", in: temp.url)
        let store = try await DocumentStore.open(url: url)

        let landed = try await store.sendHeldWordsToInbox(
            forDocId: "doc-nothing", heldBy: unsignedHolder)

        XCTAssertEqual(landed, 0)
        XCTAssertTrue(store.uiState.sentHeldSpans.isEmpty,
                      "nothing was sent, so the door stays open for the span "
                      + "that may yet arrive")
        XCTAssertTrue(store.inboxStore.entries.isEmpty)
    }

    // MARK: - Where the memory lives

    /// Per device, additive, and no key at all where the door has never been
    /// used — so a `ui-state.json` written before this task is the file it
    /// always was.
    func test_theSentMemoryIsAdditiveAndWritesNoKeyWhenEmpty() throws {
        let encoded = try JSONEncoder().encode(UIState.empty)
        for key in ["sentSetAsideRecords", "sentHeldSpans"] {
            XCTAssertFalse(
                String(decoding: encoded, as: UTF8.self).contains(key), key)
        }

        let older = try JSONDecoder().decode(
            UIState.self, from: Data("{\"schemaVersion\":1}".utf8))
        XCTAssertTrue(older.sentHeldSpans.isEmpty)
        XCTAssertTrue(older.sentSetAsideRecords.isEmpty,
                      "absent means the door has not been used, and it is "
                      + "offered once")

        var state = UIState.empty
        state.sentSetAsideRecords = ["a.lines", "b.lines"]
        state.sentHeldSpans = ["doc-1|unsigned:ghost"]
        let back = try JSONDecoder().decode(
            UIState.self, from: try JSONEncoder().encode(state))
        XCTAssertEqual(back.sentSetAsideRecords, ["a.lines", "b.lines"])
        XCTAssertEqual(back.sentHeldSpans, ["doc-1|unsigned:ghost"],
                       "the held door's memory round-trips beside it")
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

        store.recordHeldWordsSentToInbox(["doc-1|unsigned:ghost"])
        store.recordHeldWordsSentToInbox([])
        XCTAssertEqual(store.uiState.sentHeldSpans, ["doc-1|unsigned:ghost"],
                       "the held door's memory unions and never forgets either")
        XCTAssertEqual(store.uiState.sentSetAsideRecords, ["a.lines", "b.lines"],
                       "…and the two memories are two facts")
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

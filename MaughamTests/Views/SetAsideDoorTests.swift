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

        let rows = SetAsideDoor.rows(records: [record], in: project, sent: [:])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].unsent, 2)
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

        let rows = SetAsideDoor.rows(records: [record], in: project, sent: [:])

        XCTAssertEqual(rows[0].unsent, 0)
        XCTAssertFalse(rows[0].offersTheDoor,
                       "no words were taken away, so there is no door")
    }

    /// **What is left, and what was sent.** A second press must not file a
    /// paragraph the writer already has, and the note reports what the press
    /// DID rather than what is in the archive.
    func test_aRecordOffersWhatIsLeftAndSaysWhatWasSent() throws {
        let project = try makeProject()
        let record = try lines([
            burst(device: "author-abcdef0123456789",
                  paragraphs: [("p1ab", "Once only."), ("p2cd", "And again.")])
        ], in: project)
        let name = SetAsideAcknowledgement.name(for: record, in: project)
        let first = try XCTUnwrap(OpLogQuarantine.recoverableWords(
            ofRecord: record, in: project).first)

        let rows = SetAsideDoor.rows(
            records: [record], in: project,
            sent: [name: [SetAsideDoor.captureId(first)]])

        XCTAssertEqual(rows[0].unsent, 1, "one of the two is still to send")
        XCTAssertEqual(rows[0].sentCount, 1)
        XCTAssertTrue(rows[0].offersTheDoor)
        XCTAssertEqual(rows[0].sentNote, "1 paragraph sent to the Inbox",
                       "the row says what the press did rather than going quiet")

        let all = OpLogQuarantine.recoverableWords(ofRecord: record, in: project)
        let done = SetAsideDoor.rows(
            records: [record], in: project,
            sent: [name: Set(all.map(SetAsideDoor.captureId))])
        XCTAssertEqual(done[0].unsent, 0)
        XCTAssertFalse(done[0].offersTheDoor, "nothing is left to send")
        XCTAssertEqual(done[0].sentNote, "2 paragraphs sent to the Inbox")
    }

    /// And the captures a press makes are the UNSENT ones alone.
    func test_aRePressFilesOnlyTheRest() throws {
        let project = try makeProject()
        let record = try lines([
            burst(device: "author-abcdef0123456789",
                  paragraphs: [("p1ab", "First."), ("p2cd", "Second.")])
        ], in: project)
        let first = try XCTUnwrap(OpLogQuarantine.recoverableWords(
            ofRecord: record, in: project).first)

        let captures = SetAsideDoor.captures(
            forRecord: record, in: project,
            alreadySent: [SetAsideDoor.captureId(first)],
            attribution: { _ in "x" })

        XCTAssertEqual(captures.map(\.text), ["Second."])
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
            SetAsideDoor.rows(records: [record], in: project, sent: [:])[0]
                .offersTheDoor)
    }

    // MARK: - The words a press would send

    func test_theCapturesAreTheParagraphsAndWhoWroteThem() throws {
        let project = try makeProject()
        let record = try lines([
            burst(device: "assistant-abcdef0123456789",
                  paragraphs: [("p1ab", "A sentence it should not have written.")])
        ], in: project)

        let words = try XCTUnwrap(OpLogQuarantine.recoverableWords(
            ofRecord: record, in: project).first)
        let captures = SetAsideDoor.captures(
            forRecord: record, in: project,
            attribution: { "from \($0.device)" })

        XCTAssertEqual(captures, [SetAsideDoor.Capture(
            id: SetAsideDoor.captureId(words),
            text: "A sentence it should not have written.",
            attribution: "from assistant-abcdef0123456789")])
        XCTAssertEqual(captures[0].id, "\(words.opId)#p1ab",
                       "the capture is remembered by its PARAGRAPH: an op "
                       + "carrying three of them can land two")
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
            words: [unsignedHolder: 3], sent: [:])

        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].offersTheDoor)
        XCTAssertEqual(rows[0].unsent, 3)
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
            words: [personHolder: 4], sent: [:])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].unsent, 0)
        XCTAssertFalse(rows[0].offersTheDoor)
    }

    /// A re-read that found no prose — or that would not read at all — leaves
    /// the holder out of the map, and no door is offered rather than one that
    /// promises a capture nobody can make.
    func test_aReReadThatFoundNothingOffersNoDoor() throws {
        let rows = HistoryPane.heldLineRows(
            provenance: heldProvenance([unsignedHolder: 2]),
            startedAPiece: [], names: [:], words: [:], sent: [:])

        XCTAssertEqual(rows.count, 1, "the sentence is still said")
        XCTAssertEqual(rows[0].unsent, 0)
        XCTAssertFalse(rows[0].offersTheDoor)
        XCTAssertNil(rows[0].sentNote)
    }

    /// **A held span is LIVE, and this is the whole of C1** (fix round 2).
    ///
    /// Five paragraphs are sent; four more arrive. A door that closed after
    /// one press would leave those four with no way in at all — the state this
    /// door exists to remove — and a note that counted what is WAITING would
    /// tell the writer nine were sent when five were. (P3c Task 7: both counts
    /// are the store's, read off the lines — `unsignedHeldWordCounts`.)
    func test_aHeldSpanGoesOnOfferingWhatArrivesAfterThePress() throws {
        // Before: five waiting, nothing sent.
        let before = HistoryPane.heldLineRows(
            provenance: heldProvenance([unsignedHolder: 5]),
            startedAPiece: [], names: [:],
            words: [unsignedHolder: 5], sent: [:])
        XCTAssertEqual(before[0].unsent, 5)
        XCTAssertNil(before[0].sentNote)

        // The press sent those five; four more have since arrived, so the
        // store's re-read reports FOUR unsent and FIVE sent.
        let after = HistoryPane.heldLineRows(
            provenance: heldProvenance([unsignedHolder: 9]),
            startedAPiece: [], names: [:],
            words: [unsignedHolder: 4], sent: [unsignedHolder: 5])

        XCTAssertTrue(after[0].offersTheDoor,
                      "the four that arrived after the press have a way in")
        XCTAssertEqual(after[0].unsent, 4)
        XCTAssertTrue(after[0].doorHelp.contains("4 waiting paragraphs"))
        XCTAssertEqual(after[0].sentNote, "5 paragraphs sent to the Inbox",
                       "the note counts what was SENT, never what is waiting")
    }

    /// The memory is per DOCUMENT — a holder is a whole stream, and a stream
    /// runs through every chapter it wrote in. (P3c Task 7: the door key is
    /// the chapter's, and the ids carry it too.)
    func test_oneChaptersSentSpanIsNotAnothers() throws {
        XCTAssertNotEqual(SetAsideDoor.heldDoorKey(docId: "doc-1"),
                          SetAsideDoor.heldDoorKey(docId: "doc-2"))
        let words = OpLogQuarantine.SetAsideWords(
            opId: "op-1", paragraphId: "p1ab", text: "x", device: "author-x",
            at: Date(timeIntervalSince1970: 0))
        XCTAssertNotEqual(SetAsideDoor.heldLineId(docId: "doc-1", words),
                          SetAsideDoor.heldLineId(docId: "doc-2", words))

        // The behaviour, not only the strings (P3c plan 2 Task 9, restoring
        // the pin Task 7's rekey dropped): the same stream's line, sent from
        // doc-1's row, is neither counted as sent nor withheld on doc-2's.
        let doc1Sent = SetAsideDoor.heldCaptures(docId: "doc-1", words: [words], sent: [:])
        let memory = [SetAsideDoor.heldDoorKey(docId: "doc-1"): Set(doc1Sent.map(\.id))]
        XCTAssertEqual(
            SetAsideDoor.heldWordCounts(
                docId: "doc-1", wordsByHolder: [unsignedHolder: [words]], sent: memory),
            .init(unsent: [:], sent: [unsignedHolder: 1]),
            "control: doc-1's own row counts its send")
        let doc2 = SetAsideDoor.heldWordCounts(
            docId: "doc-2", wordsByHolder: [unsignedHolder: [words]], sent: memory)
        XCTAssertEqual(doc2, .init(unsent: [unsignedHolder: 1], sent: [:]),
                       "doc-2's row does not count doc-1's send")
        XCTAssertEqual(
            SetAsideDoor.heldCaptures(docId: "doc-2", words: [words], sent: memory).count, 1,
            "and doc-2's press still files its own paragraph")
    }

    // MARK: - Remembered by the lines, not by the holder (P3c Task 7, M2)

    private func heldWords(_ ids: [String]) -> [OpLogQuarantine.SetAsideWords] {
        ids.map {
            OpLogQuarantine.SetAsideWords(
                opId: $0, paragraphId: "p1ab", text: "words of \($0)",
                device: "author-ghost", at: Date(timeIntervalSince1970: 0))
        }
    }

    /// **The memory is the LINES', whichever holder they are held under** —
    /// pinned on the pure functions, because no production row exercises it
    /// today. A signing Mac whose first seal has not reached this folder is
    /// held as an unsigned stream, and the writer can send its paragraphs to
    /// the Inbox from that row. When the seal syncs, the same lines are held
    /// under a stranger or a permit-pending holder instead — and the held
    /// door counts and offers UNSIGNED holders alone
    /// (`DocumentStore.unsignedHeldWordCounts`), so today no row draws a door
    /// over them at all and nothing could re-offer them.
    ///
    /// What this pins is the rule that would hold if one ever did: a memory
    /// made under the first holder still says the sent lines were sent when
    /// they are counted under another holder's key, and does not say a line
    /// written since was. That keeps the Task 7 re-key (by line, not by holder)
    /// honest against a future change of holder or of an unsigned holder's
    /// stream key.
    func test_wordsSentUnderOneHolderAreStillSentUnderAnother() throws {
        let fingerprintHolder = String(repeating: "c3", count: 32)
        let before = heldWords(["op-1", "op-2", "op-3"])

        // The press, under the unsigned holder: what it files, recorded as it
        // lands (the store's `recordRecoveredCapturesSent`, by its door key).
        let filed = SetAsideDoor.heldCaptures(
            docId: "doc-1", words: before, sent: [:])
        XCTAssertEqual(filed.count, 3)
        let memory = [SetAsideDoor.heldDoorKey(docId: "doc-1"): Set(filed.map(\.id))]

        // The seal synced: the same three, plus one written since, held under
        // the key.
        let after = before + heldWords(["op-4"])
        let counts = SetAsideDoor.heldWordCounts(
            docId: "doc-1", wordsByHolder: [fingerprintHolder: after],
            sent: memory)
        XCTAssertEqual(counts.sent[fingerprintHolder], 3,
                       "the three already in the Inbox are still sent")
        XCTAssertEqual(counts.unsent[fingerprintHolder], 1,
                       "…and only the one never sent is offered")

        let again = SetAsideDoor.heldCaptures(
            docId: "doc-1", words: after, sent: memory)
        XCTAssertEqual(again.map(\.text), ["words of op-4"],
                       "a press now files the new paragraph and nothing else")

        // The other direction: a memory with nothing in it offers everything,
        // under either holder.
        let fresh = SetAsideDoor.heldWordCounts(
            docId: "doc-1",
            wordsByHolder: [unsignedHolder: before, fingerprintHolder: after],
            sent: [:])
        XCTAssertEqual(fresh.unsent[unsignedHolder], 3)
        XCTAssertEqual(fresh.unsent[fingerprintHolder], 4)
        XCTAssertTrue(fresh.sent.isEmpty)
    }

    /// **An older `<docId>|<holder>` key is read by nothing** (tripwire 11: no
    /// migration). The dev Macs that ran P3b hold keys in that shape; what they
    /// remember is offered once more, the safe direction — and the new door
    /// key cannot collide with one, because it has no colon.
    func test_anOlderHolderKeyedMemoryIsNotReadAndCannotCollide() throws {
        let words = heldWords(["op-1"])
        let legacy = ["doc-1|\(unsignedHolder)": Set(["op-1#p1ab"])]

        XCTAssertEqual(
            SetAsideDoor.heldCaptures(docId: "doc-1", words: words, sent: legacy)
                .count, 1)
        XCTAssertNotEqual(SetAsideDoor.heldDoorKey(docId: "doc-1"),
                          "doc-1|\(unsignedHolder)")
        XCTAssertFalse(SetAsideDoor.heldDoorKey(docId: "doc-1").contains(":"))
    }

    // MARK: - The rows follow their inputs (fix round 2, I1)

    /// **A name that arrives later is in the sentence on that same pass.** The
    /// rows used to be snapshotted in `reload()` BEFORE `reloadChain()` had
    /// resolved a single name, so a person's label was always one reload
    /// behind and a rename showed the old one.
    func test_aNameResolvedLaterIsInTheSentenceOnTheSamePass() throws {
        let provenance = heldProvenance([personHolder: 2])

        let unnamed = HistoryPane.heldLineRows(
            provenance: provenance, startedAPiece: [], names: [:])
        let named = HistoryPane.heldLineRows(
            provenance: provenance, startedAPiece: [],
            names: [personHolder: "Sam"])

        XCTAssertFalse(unnamed[0].sentence.contains("Sam"))
        XCTAssertTrue(named[0].sentence.contains("Sam"),
                      "the same provenance with a name in hand says the name")
        XCTAssertNotEqual(unnamed[0].sentence, named[0].sentence)
    }

    /// **A provenance that lands later draws its rows.** Nil is a document
    /// whose load has not finished — no rows, and no claim that it is holding
    /// nothing; the moment it lands, the same call says so.
    func test_aProvenanceThatLandsLaterDrawsItsRows() throws {
        XCTAssertTrue(HistoryPane.heldLineRows(
            provenance: nil, startedAPiece: [], names: [:]).isEmpty)
        XCTAssertEqual(HistoryPane.heldLineRows(
            provenance: heldProvenance([unsignedHolder: 2]),
            startedAPiece: [], names: [:]).count, 1)
    }

    /// **And the pane composes them live rather than holding a snapshot.**
    /// This is the half the two pure cases above cannot reach: what `body`
    /// actually reads. The disk half — the word counts — stays snapshotted and
    /// gets a `.task(id:)` of its own, keyed on the holders, so a provenance
    /// that arrives late is followed rather than waited out.
    func test_theHeldRowsAreComposedFromTheLiveProvenanceAndNames() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Maugham/Views/HistoryPane.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains("ForEach(heldRows) { row in"),
                      "the pane draws the computed rows")
        XCTAssertTrue(
            source.contains("provenance: documentProvenance,\n            startedAPiece: documentStore?"),
            "…composed from the live provenance")
        XCTAssertTrue(
            source.contains("names: chainDeviceNames, words: heldWordCounts,"),
            "…and the live names, with only the disk half stored")
        XCTAssertTrue(
            source.contains(".task(id: heldHolderKey) { await reloadHeldWordCounts() }"),
            "…and the counts follow the holders")
        XCTAssertFalse(
            source.contains("@State private var heldLineRows"),
            "the snapshot the review found is gone")
    }

    /// A stranger is left to the admission sentence, which has a control of its
    /// own — saying it twice would put two counts about one device on one
    /// screen.
    func test_aStrangerIsStillNoRowAtAll() throws {
        let stranger = String(repeating: "f1", count: 32)
        XCTAssertTrue(HistoryPane.heldLineRows(
            provenance: heldProvenance([stranger: 3], strangers: [stranger]),
            startedAPiece: [], names: [:], words: [stranger: 9],
            sent: [:]).isEmpty)
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
        XCTAssertTrue(store.uiState.sentRecoveredOpIds.isEmpty,
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
        XCTAssertFalse(
            String(decoding: encoded, as: UTF8.self)
                .contains("sentRecoveredOpIds"))

        let older = try JSONDecoder().decode(
            UIState.self, from: Data("{\"schemaVersion\":1}".utf8))
        XCTAssertTrue(older.sentRecoveredOpIds.isEmpty,
                      "absent means no capture has been made yet")

        var state = UIState.empty
        state.sentRecoveredOpIds = [
            "a.lines": ["op-1#p1ab"],
            "doc-1|unsigned:ghost": ["op-2#p2cd", "op-3#p3ef"],
        ]
        let back = try JSONDecoder().decode(
            UIState.self, from: try JSONEncoder().encode(state))
        XCTAssertEqual(back.sentRecoveredOpIds["a.lines"], ["op-1#p1ab"])
        XCTAssertEqual(back.sentRecoveredOpIds["doc-1|unsigned:ghost"]?.count, 2,
                       "both doors keep their captures in one memory")
        XCTAssertTrue(back.acknowledgedSetAsideRecords.isEmpty,
                      "the two memories are two facts: sending is not "
                      + "acknowledging")
    }

    func test_theStoresVerbUnionsAndNeverForgets() async throws {
        let temp = try TempDirectory()
        let url = try await ProjectFactory.createNovelProject(
            named: "SetasideDoor", in: temp.url)
        let store = try await DocumentStore.open(url: url)

        XCTAssertTrue(store.uiState.sentRecoveredOpIds.isEmpty)

        store.recordRecoveredCapturesSent(door: "a.lines", ids: ["op-1#p"])
        store.recordRecoveredCapturesSent(door: "a.lines", ids: ["op-2#p"])
        XCTAssertEqual(store.uiState.sentRecoveredOpIds["a.lines"],
                       ["op-1#p", "op-2#p"],
                       "the second press adds; it does not replace")

        store.recordRecoveredCapturesSent(door: "a.lines", ids: [])
        store.recordRecoveredCapturesSent(door: "", ids: ["op-3#p"])
        XCTAssertEqual(store.uiState.sentRecoveredOpIds["a.lines"],
                       ["op-1#p", "op-2#p"],
                       "an empty press is a no-op, not a clear")
        XCTAssertEqual(store.uiState.sentRecoveredOpIds.count, 1,
                       "and a door with no key writes nothing at all")

        store.recordRecoveredCapturesSent(
            door: "doc-1|unsigned:ghost", ids: ["op-9#p"])
        XCTAssertEqual(store.uiState.sentRecoveredOpIds["doc-1|unsigned:ghost"],
                       ["op-9#p"],
                       "the held door keeps its captures in the same memory")
        XCTAssertEqual(store.uiState.sentRecoveredOpIds["a.lines"]?.count, 2,
                       "…without disturbing the other door's")
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
        XCTAssertTrue(
            source.contains("documentStore.recordRecoveredCapturesSent("),
            "…which remembers the captures it made, so a re-press files only "
            + "the rest (fix round 2, C1)")
    }

    // MARK: - Fixtures

    private func makeProject() throws -> URL {
        let url = TestTemp.root
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

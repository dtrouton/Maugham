import Foundation
import XCTest
@testable import MaughamCore

/// **The permit partition — line by line, as of the line** (P3a Task 5,
/// spec §4.3–§4.5 and the §5 table).
///
/// Every row of spec §5 is a two-sided rule and appears here twice: what a
/// change leaves alone and what it takes. P2's two wrong rulings were each
/// half of a two-sided rule, which is why one direction is never enough.
///
/// The fixtures build chained, sealed bytes and walk them with the real
/// verifier, because the partition's first question — *whose key is this line
/// under* — is answered off the seals the walk found, and a hand-built
/// `Verification` would let the test decide it.
final class PermitPartitionTests: XCTestCase {

    private let docId = "doc-chapter"
    private let streamKey = "doc-chapter.sams-mac"

    /// This device's four writers. A software signer, because CI's runner has
    /// no enclave and a partition over unsigned history would be asserting the
    /// runner rather than the code (tripwire 36).
    private var mine: LocalIdentities!
    /// Sam's Mac — the other person in the book.
    private var sam: LocalIdentities!

    override func setUp() {
        super.setUp()
        mine = .softwareForTesting()
        sam = .softwareForTesting()
    }

    // MARK: - Fixtures

    private var root: String { mine.author.fingerprint }
    private var samPerson: String { sam.author.fingerprint }

    /// One file's bytes, chained and sealed for real.
    private struct Chained {
        private(set) var bytes = Data()
        private(set) var lines: [Data] = []
        private var head: String?

        mutating func append(_ json: Data) {
            let line = OpLogChain.chainedLine(elementJSON: json, prev: head ?? OpLogChain.genesis)
            bytes.append(line)
            bytes.append(0x0A)
            lines.append(line)
            head = OpLogChain.lineHash(line)
        }

        mutating func seal(by identity: DeviceIdentity, at: Date = Date(timeIntervalSince1970: 9)) throws {
            let line = try OpLogChain.Seal.line(
                head: try XCTUnwrap(head), identity: identity, at: at)
            bytes.append(line)
            bytes.append(0x0A)
            lines.append(line)
            head = OpLogChain.lineHash(line)
        }

        /// The chain hash of the line at `index` — what a mark records.
        func hash(ofLineAt index: Int) -> String { OpLogChain.lineHash(lines[index]) }
    }

    private func opJSON(
        _ opId: String, kind: OpKind = .typingBurst, by identity: DeviceIdentity
    ) throws -> Data {
        let op = Op(
            opId: opId, docId: docId, at: Date(timeIntervalSince1970: 1),
            device: identity.deviceId, session: "s", kind: kind,
            changes: [.init(paragraphId: "aaaa", prior: nil, next: opId)],
            sequence: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        return try encoder.encode(op)
    }

    /// A line whose `kind` this build has never heard of — a later build's op.
    private func futureKindJSON(_ opId: String, by identity: DeviceIdentity) throws -> Data {
        var object: [String: Any] = [
            "op_id": opId, "doc_id": docId, "at": "1970-01-01T00:00:01Z",
            "device": identity.deviceId, "session": "s",
            "kind": "epigraph_moved", "changes": [],
        ]
        object["sequence"] = nil
        return try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func permitEvent(
        _ id: String, subject: String, by signer: String,
        kind: PermitEvent.Kind = .roleChanged,
        role: String = Permit.reviewerRole,
        scope: String = Permit.bookScope,
        pieces: [String] = [],
        mark: [String: PermitMark.StreamMark] = [:]
    ) -> PermitEvent {
        PermitEvent(
            event: "\(subject).\(id)", kind: kind, subject: subject,
            role: role, scope: scope, pieces: pieces, mark: mark,
            at: Date(timeIntervalSince1970: 40), by: signer)
    }

    private func samsDeviceRecord() -> DeviceRecord {
        DeviceRecord(
            device: samPerson, name: "Sam’s Mac", kind: .mac,
            actors: [
                DeviceActor.author.rawValue: samPerson,
                DeviceActor.assistant.rawValue: sam.assistant.fingerprint,
                DeviceActor.translator.rawValue: sam.translator.fingerprint,
                DeviceActor.maugham.rawValue: sam.maugham.fingerprint,
            ],
            madeAt: Date(timeIntervalSince1970: 5))
    }

    /// The book: this Mac is the root, Sam's Mac is admitted, and `events` is
    /// whatever has happened to Sam's permit.
    private func table(events: [PermitEvent] = []) -> TrustTable {
        let registry = Registry(
            devices: [
                DeviceRecord(
                    device: root, name: "Denver’s MacBook", kind: .mac,
                    actors: [DeviceActor.author.rawValue: root],
                    madeAt: Date(timeIntervalSince1970: 1)),
                samsDeviceRecord(),
            ],
            people: [
                PersonRecord(
                    person: root, label: "Denver", ownName: "Denver’s MacBook",
                    admittedAt: Date(timeIntervalSince1970: 2), admittedBy: root),
                PersonRecord(
                    person: samPerson, label: "Sam", ownName: "Sam’s Mac",
                    admittedAt: Date(timeIntervalSince1970: 3), admittedBy: root),
            ],
            events: events)
        return TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)
    }

    /// The same book, read on SAM's Mac (P3c plan 2, Option A).
    private func tableOnSamsMac(events: [PermitEvent]) -> TrustTable {
        let registry = Registry(
            devices: [
                DeviceRecord(
                    device: root, name: "Denver’s MacBook", kind: .mac,
                    actors: [DeviceActor.author.rawValue: root],
                    madeAt: Date(timeIntervalSince1970: 1)),
                samsDeviceRecord(),
            ],
            people: [
                PersonRecord(
                    person: root, label: "Denver", ownName: "Denver’s MacBook",
                    admittedAt: Date(timeIntervalSince1970: 2), admittedBy: root),
                PersonRecord(
                    person: samPerson, label: "Sam", ownName: "Sam’s Mac",
                    admittedAt: Date(timeIntervalSince1970: 3), admittedBy: root),
            ],
            events: events)
        return TrustTable.resolve(registry: registry, mine: sam, joinedRoot: nil)
    }

    private func walk(_ file: Chained, trust: TrustTable) -> OpLogChain.Verification {
        OpLogChain.verify(
            bytes: file.bytes,
            trust: { trust.verdict(forSealKey: $0) },
            rememberedHead: nil)
    }

    private func partition(
        _ verification: OpLogChain.Verification,
        class documentClass: DocumentClass,
        trust: TrustTable,
        deviceSlug: String? = nil,
        unowned: PermitPartition.UnownedPiece = .aBookAuthorHasWrittenItsText,
        startedBy: String? = nil
    ) -> OpLogChain.Verification {
        PermitPartition.partition(
            of: verification, class: { documentClass },
            streamKey: streamKey, deviceSlug: deviceSlug,
            fileSegmentDigest: nil, trust: trust,
            unowned: { unowned }, startedBy: { startedBy })
    }

    // MARK: - Reading a result

    /// The op ids the reader would APPLY, in file order.
    private func applied(_ verification: OpLogChain.Verification) -> [String] {
        opIds(of: verification) { !$0.state.isHeldBack && $0.state != .tornTail }
    }

    private func refused(_ verification: OpLogChain.Verification) -> [String] {
        opIds(of: verification) { $0.state == .quarantined }
    }

    private func held(_ verification: OpLogChain.Verification) -> [String] {
        opIds(of: verification) { $0.state.pendingDevice != nil }
    }

    private func opIds(
        of verification: OpLogChain.Verification,
        where predicate: (OpLogChain.Line) -> Bool
    ) -> [String] {
        verification.lines.filter { $0.kind == .op && predicate($0) }.compactMap {
            let object = (try? JSONSerialization.jsonObject(with: $0.bytes)) as? [String: Any]
            return object?["op_id"] as? String
        }
    }

    private func cause(
        _ verification: OpLogChain.Verification, ofOp opId: String
    ) throws -> OpLogChain.QuarantineCause {
        for line in verification.lines where line.kind == .op {
            let object = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any]
            guard object?["op_id"] as? String == opId else { continue }
            return try XCTUnwrap(line.refusal, "\(opId) was not refused")
        }
        throw XCTSkip("no line carried \(opId)")
    }

    // MARK: - Neutrality (the gate)

    /// **A book with no events refuses nothing.** Every admitted person is an
    /// author of the whole book, which is what every P2 admission meant, so
    /// the partition hands the walk back byte for byte.
    func test_aBookWithNoEventsIsPartitionedIntoItself() throws {
        let trust = table()
        var file = Chained()
        for (index, kind) in [OpKind.typingBurst, .claudeComment, .taskCreate,
                              .checkpoint, .claudeAccept].enumerated() {
            file.append(try opJSON("op\(index)", kind: kind, by: sam.author))
        }
        try file.seal(by: sam.author)
        let walked = walk(file, trust: trust)
        XCTAssertEqual(walked.verifiedCount, 6, "the fixture really is admitted and sealed")

        let result = partition(walked, class: .piece(docId), trust: trust)

        XCTAssertEqual(result, walked, "no events, nothing refused, nothing even rebuilt")
    }

    /// The other half of neutrality: a file with no seal this device can
    /// attribute — a legacy tail, an unsigned device's — is not judged at all.
    func test_aFileWithNoAttributableSealIsUntouched() throws {
        let trust = table()
        var file = Chained()
        file.append(try opJSON("op0", by: sam.author))
        file.append(try opJSON("op1", by: sam.author))
        let walked = walk(file, trust: trust)
        XCTAssertEqual(walked.unsealedCount, 2)

        XCTAssertEqual(partition(walked, class: .piece(docId), trust: trust), walked)
    }

    /// **Unsigned history still applies** (decision B3, P1's whole world). A
    /// seal from a key with no chain here answers `.noChain`, and P3 does not
    /// start refusing what P1 applied.
    func test_unsignedHistoryIsNotJudgedByAnyPermit() throws {
        let stranger = LocalIdentities.softwareForTesting()
        // An empty registry: this device knows its own hand and nothing else.
        let trust = TrustResolution.keyless(mine: mine)
        var file = Chained()
        file.append(try opJSON("op0", by: stranger.author))
        try file.seal(by: stranger.author)
        let walked = walk(file, trust: trust)
        XCTAssertEqual(walked.lines.first?.state, .unsignedHistory)

        XCTAssertEqual(partition(walked, class: .piece(docId), trust: trust), walked)
        XCTAssertEqual(applied(partition(walked, class: .piece(docId), trust: trust)), ["op0"])
    }

    // MARK: - §5 row 1 — demotion, both directions

    /// **What stays**: everything at or before the mark. **What changes**: her
    /// manuscript lines after it are set aside in her name.
    func test_aDemotionLeavesWhatCameBeforeItAndTakesWhatCameAfter() throws {
        var file = Chained()
        file.append(try opJSON("before1", by: sam.author))
        file.append(try opJSON("before2", by: sam.author))
        file.append(try opJSON("after1", by: sam.author))
        file.append(try opJSON("after2", by: sam.author))
        try file.seal(by: sam.author)

        let trust = table(events: [
            permitEvent("a", subject: samPerson, by: root, kind: .admitted,
                        role: Permit.authorRole),
            permitEvent("b", subject: samPerson, by: root, kind: .roleChanged,
                        role: Permit.reviewerRole,
                        mark: [streamKey: .init(line: file.hash(ofLineAt: 1))]),
        ])
        let result = partition(walk(file, trust: trust), class: .piece(docId), trust: trust)

        XCTAssertEqual(applied(result), ["before1", "before2"],
                       "what she wrote before then stays in the book")
        XCTAssertEqual(refused(result), ["after1", "after2"])
        XCTAssertEqual(
            try cause(result, ofOp: "after1"),
            .notPermitted(person: samPerson, what: .manuscriptText,
                          afterMark: true, actor: DeviceActor.author.rawValue))
    }

    /// The same demotion does not touch what a reviewer MAY write: her notes
    /// after the mark are applied.
    func test_aDemotedAuthorsNotesAfterTheMarkAreStillApplied() throws {
        var file = Chained()
        file.append(try opJSON("before", by: sam.author))
        file.append(try opJSON("note", kind: .claudeComment, by: sam.author))
        file.append(try opJSON("text", by: sam.author))
        try file.seal(by: sam.author)

        let trust = table(events: [
            permitEvent("a", subject: samPerson, by: root, kind: .admitted,
                        role: Permit.authorRole),
            permitEvent("b", subject: samPerson, by: root, kind: .roleChanged,
                        role: Permit.reviewerRole,
                        mark: [streamKey: .init(line: file.hash(ofLineAt: 0))]),
        ])
        let result = partition(walk(file, trust: trust), class: .piece(docId), trust: trust)

        XCTAssertEqual(applied(result), ["before", "note"],
                       "line by line — a note is something a reviewer may write")
        XCTAssertEqual(refused(result), ["text"])
    }

    // MARK: - §5 row 2 — promotion, both directions

    /// **A promotion is not a pardon**: what she signed while the permit said
    /// no stays set aside. **What changes**: lines after the mark are applied.
    func test_aPromotionAppliesWhatComesAfterItAndPardonsNothingBefore() throws {
        var file = Chained()
        file.append(try opJSON("asReviewer", by: sam.author))
        file.append(try opJSON("asAuthor", by: sam.author))
        try file.seal(by: sam.author)

        let trust = table(events: [
            permitEvent("a", subject: samPerson, by: root, kind: .admitted,
                        role: Permit.reviewerRole),
            permitEvent("b", subject: samPerson, by: root, kind: .roleChanged,
                        role: Permit.authorRole,
                        mark: [streamKey: .init(line: file.hash(ofLineAt: 0))]),
        ])
        let result = partition(walk(file, trust: trust), class: .piece(docId), trust: trust)

        XCTAssertEqual(applied(result), ["asAuthor"])
        XCTAssertEqual(refused(result), ["asReviewer"],
                       "a promotion is not a pardon")
        XCTAssertEqual(
            try cause(result, ofOp: "asReviewer"),
            .notPermitted(person: samPerson, what: .manuscriptText,
                          afterMark: false, actor: DeviceActor.author.rawValue),
            "written under the permit she was admitted with — nothing changed first")
    }

    // MARK: - §5 row 1's scope half, both directions

    /// A piece LEAVES her scope: what she wrote in it before stays, what she
    /// writes in it after is set aside.
    func test_aPieceLeavingHerScopeKeepsWhatCameBeforeTheMark() throws {
        var file = Chained()
        file.append(try opJSON("hers", by: sam.author))
        file.append(try opJSON("notHersAnyMore", by: sam.author))
        try file.seal(by: sam.author)

        let trust = table(events: [
            permitEvent("a", subject: samPerson, by: root, kind: .admitted,
                        role: Permit.authorRole, scope: Permit.piecesScope,
                        pieces: [docId]),
            permitEvent("b", subject: samPerson, by: root, kind: .scopeChanged,
                        role: Permit.authorRole, scope: Permit.piecesScope,
                        pieces: ["doc-other"],
                        mark: [streamKey: .init(line: file.hash(ofLineAt: 0))]),
        ])
        let result = partition(walk(file, trust: trust), class: .piece(docId), trust: trust)

        XCTAssertEqual(applied(result), ["hers"])
        XCTAssertEqual(refused(result), ["notHersAnyMore"])
    }

    /// A piece JOINS her scope: what she wrote before stays refused, what she
    /// writes after is applied.
    func test_aPieceJoiningHerScopeAppliesWhatComesAfterTheMark() throws {
        var file = Chained()
        file.append(try opJSON("tooEarly", by: sam.author))
        file.append(try opJSON("hersNow", by: sam.author))
        try file.seal(by: sam.author)

        let trust = table(events: [
            permitEvent("a", subject: samPerson, by: root, kind: .admitted,
                        role: Permit.authorRole, scope: Permit.piecesScope,
                        pieces: ["doc-other"]),
            permitEvent("b", subject: samPerson, by: root, kind: .scopeChanged,
                        role: Permit.authorRole, scope: Permit.piecesScope,
                        pieces: ["doc-other", docId],
                        mark: [streamKey: .init(line: file.hash(ofLineAt: 0))]),
        ])
        let result = partition(
            walk(file, trust: trust), class: .piece(docId), trust: trust)

        XCTAssertEqual(applied(result), ["hersNow"])
        XCTAssertEqual(refused(result), ["tooEarly"])
    }

    // MARK: - §5 row 6 — the root on her piece

    /// **Applied, always.** The root is whole-book at storage whatever the
    /// board says; the app warns first, and that warning is §8's, not this
    /// function's.
    func test_theRootWritingInSomebodyElsesPieceIsApplied() throws {
        var file = Chained()
        file.append(try opJSON("rootsEdit", by: mine.author))
        try file.seal(by: mine.author)

        let trust = table(events: [
            permitEvent("a", subject: samPerson, by: root, kind: .admitted,
                        role: Permit.authorRole, scope: Permit.piecesScope,
                        pieces: [docId]),
        ])
        let result = partition(walk(file, trust: trust), class: .piece(docId), trust: trust)

        XCTAssertEqual(applied(result), ["rootsEdit"])
        XCTAssertTrue(refused(result).isEmpty)
    }

    // MARK: - The actor rows, on this device's own hand

    /// **`.mine` lines are partitioned too.** The assistant is the reviewer
    /// row on every device including the root's — *MCP never mutates
    /// manuscript text* at the storage layer — so an assistant-signed
    /// manuscript line in this Mac's OWN file is refused.
    func test_theAssistantsManuscriptLineIsRefusedInThisDevicesOwnFile() throws {
        let trust = table()
        var file = Chained()
        file.append(try opJSON("aNote", kind: .claudeComment, by: mine.assistant))
        file.append(try opJSON("aParagraph", by: mine.assistant))
        try file.seal(by: mine.assistant)
        let walked = walk(file, trust: trust)
        XCTAssertEqual(walked.lines.first?.state, .verified, "this device's own word")

        let result = partition(walked, class: .piece(docId), trust: trust)

        XCTAssertEqual(applied(result), ["aNote"], "a note is the assistant's row")
        XCTAssertEqual(refused(result), ["aParagraph"])
        XCTAssertEqual(
            try cause(result, ofOp: "aParagraph"),
            .notPermitted(person: root, what: .manuscriptText,
                          afterMark: false, actor: DeviceActor.assistant.rawValue))
    }

    /// The translator's row, from a foreign device, with the same shape.
    func test_theTranslatorsManuscriptLineIsRefusedWhoeverHoldsTheKey() throws {
        let trust = table()
        var file = Chained()
        file.append(try opJSON("aParagraph", by: sam.translator))
        try file.seal(by: sam.translator)

        let result = partition(walk(file, trust: trust), class: .piece(docId), trust: trust)

        XCTAssertEqual(refused(result), ["aParagraph"])
        XCTAssertEqual(
            try cause(result, ofOp: "aParagraph"),
            .notPermitted(person: samPerson, what: .manuscriptText,
                          afterMark: false, actor: DeviceActor.translator.rawValue))
    }

    /// The rebalance's own row is ALLOWED — the one thing `maugham` signs.
    func test_theTaskRebalanceIsAllowedOnTheProjectStream() throws {
        let trust = table()
        var file = Chained()
        file.append(try opJSON("rebalance", kind: .taskPriorityChange, by: mine.maugham))
        try file.seal(by: mine.maugham)
        let walked = walk(file, trust: trust)

        XCTAssertEqual(partition(walked, class: .projectStream, trust: trust), walked)
    }

    // MARK: - Pending, never set aside

    /// **An op kind this build has never heard of is HELD — where the line is
    /// being judged at all.** An older Mac must not quarantine what a newer
    /// one would apply, so it is not applied and not recorded either: no
    /// `.lines` record, nothing set aside.
    func test_anUnknownOpKindIsHeldWhereTheLineIsJudged() throws {
        let trust = table()
        var file = Chained()
        file.append(try futureKindJSON("fromTomorrow", by: sam.assistant))
        file.append(try opJSON("today", kind: .claudeComment, by: sam.assistant))
        try file.seal(by: sam.assistant)

        let result = partition(walk(file, trust: trust), class: .piece(docId), trust: trust)

        XCTAssertEqual(held(result), ["fromTomorrow"])
        XCTAssertTrue(refused(result).isEmpty, "nothing is wrong with it")
        XCTAssertTrue(result.quarantined.isEmpty)
        XCTAssertEqual(applied(result), ["today"])
    }

    /// **And a book author's own hand is not judged at all, so her unknown
    /// kind is left to the parser exactly as it was before P3** (fix round 1,
    /// I3's ruling).
    ///
    /// She may write everything, so there is no narrower build for a hold to
    /// be protecting, and `OpKind`'s own `.unknown` decode is P2's answer for
    /// such a line — the deriver folds it inertly. Holding it would be a
    /// behaviour change on every existing book, for a line nobody can act on.
    func test_aBookAuthorsUnknownKindIsNotHeld() throws {
        let trust = table()
        var file = Chained()
        file.append(try futureKindJSON("fromTomorrow", by: sam.author))
        file.append(try opJSON("today", by: sam.author))
        try file.seal(by: sam.author)
        let walked = walk(file, trust: trust)

        let result = partition(walked, class: .piece(docId), trust: trust)

        XCTAssertEqual(result, walked, "the partition never looked at the line")
        XCTAssertTrue(held(result).isEmpty)
        XCTAssertTrue(refused(result).isEmpty)
    }

    /// **A role word this build cannot read holds that person's lines**, for
    /// the same reason and through the same arm.
    func test_aPermitThisBuildCannotReadHoldsHerLines() throws {
        var file = Chained()
        file.append(try opJSON("op0", by: sam.author))
        try file.seal(by: sam.author)

        let trust = table(events: [
            permitEvent("a", subject: samPerson, by: root, kind: .roleChanged,
                        role: "curator",
                        mark: [streamKey: .init(line: "not this file's line")]),
        ])
        let result = partition(walk(file, trust: trust), class: .piece(docId), trust: trust)

        XCTAssertEqual(held(result), ["op0"])
        XCTAssertTrue(result.quarantined.isEmpty)
    }

    // MARK: - §4.5 — her new piece

    /// Her manuscript lines in a piece **nobody has written the text of** are
    /// PENDING: the writer is asked whose the piece is, and nothing is set
    /// aside while the question stands.
    func test_herLinesInAPieceNobodyHasWrittenArePending() throws {
        var file = Chained()
        file.append(try opJSON("herOpening", by: sam.author))
        try file.seal(by: sam.author)

        let trust = table(events: [
            permitEvent("a", subject: samPerson, by: root, kind: .admitted,
                        role: Permit.authorRole, scope: Permit.piecesScope,
                        pieces: ["doc-hers"]),
        ])
        let result = partition(
            walk(file, trust: trust), class: .piece(docId), trust: trust,
            unowned: .nobodyHasWrittenItsText)

        XCTAssertEqual(held(result), ["herOpening"])
        XCTAssertTrue(result.quarantined.isEmpty, "a question, not a violation")
    }

    // MARK: - Option A: her own Mac (P3c plan 2) — the three guards, one at a time

    private func samAuthorOf(_ pieces: [String]) -> PermitEvent {
        permitEvent("a", subject: samPerson, by: root, kind: .admitted,
                    role: Permit.authorRole, scope: Permit.piecesScope,
                    pieces: pieces)
    }

    private func herOpeningFile() throws -> Chained {
        var file = Chained()
        file.append(try opJSON("herOpening", by: sam.author))
        try file.seal(by: sam.author)
        return file
    }

    /// All three guards hold — the line is hers, the piece is one she started,
    /// and it was not taken from her: applied on HER Mac, held on the root's.
    func test_herLinesInAPieceSheStartedApplyOnHerMacOnly() throws {
        let events = [samAuthorOf(["doc-hers"])]
        let file = try herOpeningFile()

        let onHers = tableOnSamsMac(events: events)
        let mine = partition(
            walk(file, trust: onHers), class: .piece(docId), trust: onHers,
            unowned: .nobodyHasWrittenItsText, startedBy: sam.author.deviceId)
        XCTAssertEqual(applied(mine), ["herOpening"])

        let onRoots = table(events: events)
        let theirs = partition(
            walk(file, trust: onRoots), class: .piece(docId), trust: onRoots,
            unowned: .nobodyHasWrittenItsText, startedBy: sam.author.deviceId)
        XCTAssertEqual(held(theirs), ["herOpening"])
    }

    /// **Guard 1 alone — the LINE must be this writer's.** On the root's Mac,
    /// with the manifest naming HER device as the starter, the starter is hers
    /// but this Mac is not: her line is held and the root is asked. (Review
    /// M2's case — a manifest naming the root's own device — is now F1's, and
    /// is refused below.)
    func test_guardOneTheLineMustBeThisWritersOwn() throws {
        let trust = table(events: [samAuthorOf(["doc-hers"])])
        let result = partition(
            walk(try herOpeningFile(), trust: trust), class: .piece(docId),
            trust: trust, unowned: .nobodyHasWrittenItsText,
            startedBy: sam.author.deviceId)
        XCTAssertEqual(held(result), ["herOpening"])
        XCTAssertTrue(applied(result).isEmpty)
    }

    /// **Guard 2 alone — the PIECE must be one her devices started.** Her own
    /// Mac, her own line, a piece with no starter recorded (made before this
    /// build): §4.5's question, exactly as before. (A piece the root started
    /// is no longer a question at all — F1, below.)
    func test_guardTwoThePieceMustBeOneSheStarted() throws {
        let trust = tableOnSamsMac(events: [samAuthorOf(["doc-hers"])])
        let result = partition(
            walk(try herOpeningFile(), trust: trust), class: .piece(docId),
            trust: trust, unowned: .nobodyHasWrittenItsText, startedBy: nil)
        XCTAssertEqual(held(result), ["herOpening"])
        XCTAssertTrue(result.quarantined.isEmpty)
    }

    // MARK: - F1 (P3 closing smoke): a piece somebody ELSE started is outside her scope

    /// The partition with the §4.5 carrier attached, so a test can see
    /// whether the line was filed as *she started a piece* — the fact the
    /// load question is raised from.
    private func partitionRecording(
        _ verification: OpLogChain.Verification, trust: TrustTable,
        startedBy: String?
    ) -> (OpLogChain.Verification, AmendmentPermits) {
        let amendments = AmendmentPermits()
        let result = PermitPartition.partition(
            of: verification, class: { .piece(self.docId) },
            streamKey: streamKey, deviceSlug: nil,
            fileSegmentDigest: nil, trust: trust,
            recordingAmendmentsInto: amendments,
            unowned: { .nobodyHasWrittenItsText }, startedBy: { startedBy })
        return (result, amendments)
    }

    /// **F1, as the smoke found it.** The root's Mac; a piece the manifest
    /// records the ROOT's own device as starting, no op log of its own yet;
    /// Sam — an author of other pieces — writes in it. Denver's ruling
    /// (2026-09-26): refuse, don't ask. Her line is set aside like any
    /// out-of-scope line, and nothing records it as *she started a piece*,
    /// so no load question can be raised about it.
    func test_F1_herLineInAPieceTheRootStartedIsRefusedOnTheRootsMacAndNotAsked() throws {
        let trust = table(events: [samAuthorOf(["doc-hers"])])
        let (result, amendments) = partitionRecording(
            walk(try herOpeningFile(), trust: trust), trust: trust,
            startedBy: mine.author.deviceId)
        XCTAssertEqual(refused(result), ["herOpening"])
        XCTAssertTrue(held(result).isEmpty, "a refusal, not a question")
        XCTAssertTrue(amendments.whoStartedAPiece.isEmpty,
                      "the load question is raised from this, and must not be")
    }

    /// **The same line on HER own Mac is refused too.** Option A's own-Mac arm
    /// is for a piece she started; a piece the root started is not hers here
    /// either, so her Mac does not show her words the book will set aside.
    func test_F1_herLineInAPieceTheRootStartedIsRefusedOnHerOwnMac() throws {
        let trust = tableOnSamsMac(events: [samAuthorOf(["doc-hers"])])
        let (result, amendments) = partitionRecording(
            walk(try herOpeningFile(), trust: trust), trust: trust,
            startedBy: mine.author.deviceId)
        XCTAssertEqual(refused(result), ["herOpening"])
        XCTAssertTrue(held(result).isEmpty)
        XCTAssertTrue(applied(result).isEmpty)
        XCTAssertTrue(amendments.whoStartedAPiece.isEmpty)
    }

    /// **The other direction — a piece SHE started keeps Option A on both
    /// Macs.** Her own Mac applies; the root's holds, and records it as
    /// *she started a piece*, so the root is asked.
    func test_F1_aPieceSheStartedIsStillAQuestionOnTheRootsMac() throws {
        let trust = table(events: [samAuthorOf(["doc-hers"])])
        let (result, amendments) = partitionRecording(
            walk(try herOpeningFile(), trust: trust), trust: trust,
            startedBy: sam.author.deviceId)
        XCTAssertEqual(held(result), ["herOpening"])
        XCTAssertTrue(result.quarantined.isEmpty)
        XCTAssertEqual(amendments.whoStartedAPiece, [samPerson])
    }

    /// **And a legacy piece — no starter recorded — keeps §4.5's question**
    /// on the root's Mac.
    func test_F1_aPieceWithNoRecordedStarterIsStillAQuestion() throws {
        let trust = table(events: [samAuthorOf(["doc-hers"])])
        let (result, amendments) = partitionRecording(
            walk(try herOpeningFile(), trust: trust), trust: trust,
            startedBy: nil)
        XCTAssertEqual(held(result), ["herOpening"])
        XCTAssertTrue(result.quarantined.isEmpty)
        XCTAssertEqual(amendments.whoStartedAPiece, [samPerson])
    }

    /// **A starter this register cannot name yet waits** — it may be her own
    /// other Mac whose record has not synced, and a refusal made on a guess
    /// would set her words aside. Held, as before the ruling; the ruling is
    /// about a starter the register KNOWS is somebody else.
    func test_F1_aStarterThisRegisterCannotNameStillWaits() throws {
        let trust = table(events: [samAuthorOf(["doc-hers"])])
        let stranger = LocalIdentities.softwareForTesting()
        let (result, _) = partitionRecording(
            walk(try herOpeningFile(), trust: trust), trust: trust,
            startedBy: stranger.author.deviceId)
        XCTAssertEqual(held(result), ["herOpening"])
        XCTAssertTrue(result.quarantined.isEmpty)
    }

    /// **A *Theirs* the root already gave stands.** *Theirs* is a signed
    /// permit event that settles the piece into her scope, so the table
    /// answers `.yes` before the starter is ever read: her line applies, no
    /// refusal contradicts the answer, and no question comes back.
    func test_F1_aTheirsAlreadyGivenForARootStartedPieceStillApplies() throws {
        let theirs = PermitEvent(
            event: "\(samPerson).b", kind: .scopeChanged, subject: samPerson,
            role: Permit.authorRole, scope: Permit.piecesScope,
            pieces: ["doc-hers", docId], settled: [docId],
            at: Date(timeIntervalSince1970: 41), by: root)
        let trust = table(events: [samAuthorOf(["doc-hers"]), theirs])
        let (result, amendments) = partitionRecording(
            walk(try herOpeningFile(), trust: trust), trust: trust,
            startedBy: mine.author.deviceId)
        XCTAssertEqual(applied(result), ["herOpening"])
        XCTAssertTrue(result.quarantined.isEmpty)
        XCTAssertTrue(amendments.whoStartedAPiece.isEmpty)
    }

    /// **Guard 3 alone — not TAKEN from her named pieces.** Her Mac, her line,
    /// a piece she started, but the root once listed it in her scope and then
    /// removed it: held. And a writer narrowed from the WHOLE book is not
    /// thereby "taken from" — a piece she starts afterwards applies.
    func test_guardThreeAPieceTakenFromHerNamedPiecesIsHeld() throws {
        let taken = tableOnSamsMac(events: [
            samAuthorOf(["doc-hers", docId]),
            permitEvent("b", subject: samPerson, by: root, kind: .scopeChanged,
                        role: Permit.authorRole, scope: Permit.piecesScope,
                        pieces: ["doc-hers"]),
        ])
        let held1 = partition(
            walk(try herOpeningFile(), trust: taken), class: .piece(docId),
            trust: taken, unowned: .nobodyHasWrittenItsText,
            startedBy: sam.author.deviceId)
        XCTAssertEqual(held(held1), ["herOpening"])

        let narrowed = tableOnSamsMac(events: [
            permitEvent("a", subject: samPerson, by: root, kind: .roleChanged,
                        role: Permit.authorRole, scope: Permit.piecesScope,
                        pieces: ["doc-hers"]),
        ])
        let applied1 = partition(
            walk(try herOpeningFile(), trust: narrowed), class: .piece(docId),
            trust: narrowed, unowned: .nobodyHasWrittenItsText,
            startedBy: sam.author.deviceId)
        XCTAssertEqual(applied(applied1), ["herOpening"],
                       "narrowed from the whole book: nobody took this piece")
    }

    /// The other direction: where a book author HAS written the piece's text,
    /// the piece is theirs and her lines are set aside.
    func test_herLinesInAPieceABookAuthorHasWrittenAreSetAside() throws {
        var file = Chained()
        file.append(try opJSON("herOpening", by: sam.author))
        try file.seal(by: sam.author)

        let trust = table(events: [
            permitEvent("a", subject: samPerson, by: root, kind: .admitted,
                        role: Permit.authorRole, scope: Permit.piecesScope,
                        pieces: ["doc-hers"]),
        ])
        let result = partition(
            walk(file, trust: trust), class: .piece(docId), trust: trust,
            unowned: .aBookAuthorHasWrittenItsText)

        XCTAssertEqual(refused(result), ["herOpening"])
        XCTAssertTrue(held(result).isEmpty)
    }

    /// **Pending→refused is the only direction.** The same file under the two
    /// answers: held while nobody has claimed it, refused once somebody has —
    /// and never the reverse, because the answer is a fact that only ever
    /// becomes more true.
    func test_theNewPieceQuestionOnlyEverHardens() throws {
        var file = Chained()
        file.append(try opJSON("herOpening", by: sam.author))
        try file.seal(by: sam.author)
        let trust = table(events: [
            permitEvent("a", subject: samPerson, by: root, kind: .admitted,
                        role: Permit.authorRole, scope: Permit.piecesScope,
                        pieces: ["doc-hers"]),
        ])
        let walked = walk(file, trust: trust)

        let pending = partition(
            walked, class: .piece(docId), trust: trust,
            unowned: .nobodyHasWrittenItsText)
        let hardened = partition(
            walked, class: .piece(docId), trust: trust,
            unowned: .aBookAuthorHasWrittenItsText)

        XCTAssertEqual(held(pending), ["herOpening"])
        XCTAssertEqual(refused(hardened), ["herOpening"])
        XCTAssertTrue(refused(pending).isEmpty,
                      "nothing was applied while the question stood, so nothing is lost")
    }

    /// The §4.5 arm is the SCOPE's, not the actor's: an assistant-signed
    /// manuscript line in an unclaimed piece is refused whatever the answer,
    /// because the assistant never changes the manuscript anywhere.
    func test_theNewPieceQuestionDoesNotCoverTheAssistantsHand() throws {
        var file = Chained()
        file.append(try opJSON("assistantText", by: sam.assistant))
        try file.seal(by: sam.assistant)

        let trust = table(events: [
            permitEvent("a", subject: samPerson, by: root, kind: .admitted,
                        role: Permit.authorRole, scope: Permit.piecesScope,
                        pieces: ["doc-hers"]),
        ])
        let result = partition(
            walk(file, trust: trust), class: .piece(docId), trust: trust,
            unowned: .nobodyHasWrittenItsText)

        XCTAssertEqual(refused(result), ["assistantText"])
    }

    /// `bookAuthorWroteManuscriptText` is what the caller computes the answer
    /// with — both directions, over the same shape the partition reads.
    func test_theUnownedAnswerIsDerivedFromABookAuthorsOwnHand() throws {
        let trust = table(events: [
            permitEvent("a", subject: samPerson, by: root, kind: .admitted,
                        role: Permit.authorRole, scope: Permit.piecesScope,
                        pieces: ["doc-hers"]),
        ])

        var rootsText = Chained()
        rootsText.append(try opJSON("rootText", by: mine.author))
        try rootsText.seal(by: mine.author)
        XCTAssertTrue(PermitPartition.bookAuthorWroteManuscriptText(
            in: walk(rootsText, trust: trust), streamKey: streamKey,
            fileSegmentDigest: nil, trust: trust))

        var rootsNote = Chained()
        rootsNote.append(try opJSON("rootNote", kind: .claudeComment, by: mine.author))
        try rootsNote.seal(by: mine.author)
        XCTAssertFalse(
            PermitPartition.bookAuthorWroteManuscriptText(
                in: walk(rootsNote, trust: trust), streamKey: streamKey,
                fileSegmentDigest: nil, trust: trust),
            "somebody's NOTES on it do not make it theirs")

        var scopedText = Chained()
        scopedText.append(try opJSON("herText", by: sam.author))
        try scopedText.seal(by: sam.author)
        XCTAssertFalse(
            PermitPartition.bookAuthorWroteManuscriptText(
                in: walk(scopedText, trust: trust), streamKey: streamKey,
                fileSegmentDigest: nil, trust: trust),
            "an author of SOME pieces has not claimed it by writing in it")

        var assistantText = Chained()
        assistantText.append(try opJSON("assistantText", by: mine.assistant))
        try assistantText.seal(by: mine.assistant)
        XCTAssertFalse(
            PermitPartition.bookAuthorWroteManuscriptText(
                in: walk(assistantText, trust: trust), streamKey: streamKey,
                fileSegmentDigest: nil, trust: trust),
            "the assistant's hand is the reviewer row on every device")
    }

    // MARK: - The mechanics

    /// **A seal travels with the op immediately before it.** It carries no op
    /// id and the span it closes ends at the line above it, so leaving the
    /// signature applied over a line just taken out of the book would file it
    /// under a position its own op no longer has.
    func test_aSealTravelsWithTheOpImmediatelyBeforeIt() throws {
        let trust = table()
        var file = Chained()
        file.append(try opJSON("aNote", kind: .claudeComment, by: mine.assistant))
        try file.seal(by: mine.assistant)
        file.append(try opJSON("aParagraph", by: mine.assistant))
        try file.seal(by: mine.assistant)

        let result = partition(walk(file, trust: trust), class: .piece(docId), trust: trust)

        XCTAssertEqual(result.lines.map(\.state),
                       [.verified, .verified, .quarantined, .quarantined],
                       "the first seal stays with its applied note; the second goes "
                       + "with the paragraph it closes")
    }

    /// The trailing span no seal has closed yet belongs to the last seal
    /// before it — otherwise *stop sealing* would be a way past the whole
    /// check, and a live tail's newest lines are always unsealed.
    func test_theTrailingUnsealedSpanIsJudgedUnderTheLastSealsKey() throws {
        let trust = table()
        var file = Chained()
        file.append(try opJSON("sealed", kind: .claudeComment, by: mine.assistant))
        try file.seal(by: mine.assistant)
        file.append(try opJSON("neverSealed", by: mine.assistant))
        let walked = walk(file, trust: trust)
        XCTAssertEqual(walked.lines.last?.state, .unsealed, "the fixture's tail is open")

        let result = partition(walked, class: .piece(docId), trust: trust)

        XCTAssertEqual(refused(result), ["neverSealed"])
    }

    /// A file's refusals keep their own causes, and `setAside` files one
    /// record per cause: two lines refused for two different things are two
    /// records, not one.
    ///
    /// The task line is a `taskStatusChange` rather than a `taskCreate` since
    /// the final fix wave's W3(a): `taskCreate` is one of the two kinds the
    /// LOAD emits on its own account, so an assistant-signed one is the app's
    /// own housekeeping and is judged as the author's. Every other kind in the
    /// `.task` group is still the assistant's to be refused, and this test is
    /// about two causes rather than about which kind carries the second.
    func test_twoLinesRefusedForDifferentThingsCarryTheirOwnCauses() throws {
        let trust = table()
        var file = Chained()
        file.append(try opJSON("text", by: mine.assistant))
        file.append(try opJSON("task", kind: .taskStatusChange, by: mine.assistant))
        try file.seal(by: mine.assistant)

        let result = partition(walk(file, trust: trust), class: .piece(docId), trust: trust)

        XCTAssertEqual(
            try cause(result, ofOp: "text"),
            .notPermitted(person: root, what: .manuscriptText,
                          afterMark: false, actor: DeviceActor.assistant.rawValue))
        XCTAssertEqual(
            try cause(result, ofOp: "task"),
            .notPermitted(person: root, what: .task,
                          afterMark: false, actor: DeviceActor.assistant.rawValue))
        var distinct: [OpLogChain.QuarantineCause] = []
        for refusal in result.lines.compactMap(\.refusal)
        where !distinct.contains(refusal) { distinct.append(refusal) }
        XCTAssertEqual(distinct.count, 2,
                       "two causes, so `setAside` writes two records")
    }

    /// The partition never moves the head: it decides what the DOCUMENT is
    /// made of, not what the file's next line chains onto.
    func test_thePartitionNeverMovesTheHead() throws {
        let trust = table()
        var file = Chained()
        file.append(try opJSON("aParagraph", by: mine.assistant))
        try file.seal(by: mine.assistant)
        let walked = walk(file, trust: trust)

        let result = partition(walked, class: .piece(docId), trust: trust)

        XCTAssertFalse(refused(result).isEmpty, "the fixture really refuses something")
        XCTAssertEqual(result.head, walked.head)
    }

    // MARK: - The sentences

    /// Every refusal this cause can carry has a clause of its own, in the same
    /// register as the five `quarantineReason` already had: one lower-case
    /// phrase about the event, with no label, no count and no name in it.
    func test_everyPermitRefusalHasItsOwnSentence() {
        func reason(
            _ what: RefusedWhat, afterMark: Bool = false, actor: String? = nil
        ) -> String {
            JSONLAppendStore<Op>.quarantineReason(
                .notPermitted(person: "p", what: what, afterMark: afterMark, actor: actor))
        }

        XCTAssertEqual(
            reason(.manuscriptText, actor: DeviceActor.assistant.rawValue),
            "written by the assistant, which never changes the manuscript")
        for name in [reason(.manuscriptText, actor: DeviceActor.assistant.rawValue),
                     reason(.other, actor: DeviceActor.translator.rawValue),
                     reason(.task, actor: DeviceActor.maugham.rawValue)] {
            XCTAssertFalse(name.lowercased().contains("claude"),
                           "the AI actor is never given a product name")
        }
        XCTAssertEqual(
            reason(.manuscriptText),
            "written into the manuscript by a device that may not write it here")
        XCTAssertEqual(
            reason(.manuscriptText, afterMark: true),
            "written into the manuscript by a device after its permission here changed")

        // Every noun is spelled, and no two share a sentence.
        let clauses = RefusedWhat.allCases.map { reason($0) }
        XCTAssertEqual(Set(clauses).count, RefusedWhat.allCases.count)
        for (noun, clause) in zip(RefusedWhat.allCases, clauses) {
            XCTAssertFalse(clause.isEmpty, "\(noun) has a clause")
            XCTAssertNotEqual(
                clause,
                JSONLAppendStore<Op>.quarantineReason(.chainBroke(.prevMismatch(lineIndex: 0))),
                "\(noun) does not fall through to the chain's sentence")
        }
    }
}

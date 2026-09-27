import XCTest
@testable import Maugham
@testable import MaughamCore

/// **People & Devices, as a released book drew it** (v0.41.1).
///
/// A real book — one writer, one Mac and one iPhone — drew TWO people under
/// the writer's name (the phone was admitted under the Mac's label and its
/// build wrote no device record), and a column of *Nothing this book holds
/// says who signs for …* rows about the writer's own pre-signing history, one
/// of them naming a DOCUMENT id as though it signed something.
///
/// Every rule here is stated in both directions and pinned on the model, with
/// nothing mounted. The fixture mirrors that book's register SHAPE with
/// synthetic content: a root record and an admitted record under one label,
/// the second with no device record; and the five legacy stream spellings
/// beside one signing-era stream.
@MainActor
final class PeopleAndDevicesOneWriterTests: XCTestCase {

    private var mac: DeviceIdentity!
    private var phone: DeviceIdentity!
    private var sam: DeviceIdentity!
    private var samsPhone: DeviceIdentity!

    override func setUp() async throws {
        mac = .softwareForTesting()
        phone = .softwareForTesting()
        sam = .softwareForTesting()
        samsPhone = .softwareForTesting()
    }

    private let made = Date(timeIntervalSince1970: 1_756_000_000)
    private let admitted = Date(timeIntervalSince1970: 1_757_000_000)
    private let later = Date(timeIntervalSince1970: 1_758_000_000)

    private let pieces = [PermitControl.Piece(id: "ch4", title: "Chapter 4")]

    private func device(_ identity: DeviceIdentity, name: String, kind: DeviceKind) -> DeviceRecord {
        DeviceRecord(
            device: identity.fingerprint, name: name, kind: kind,
            actors: [DeviceActor.author.rawValue: identity.fingerprint], madeAt: made)
    }

    private func person(
        _ identity: DeviceIdentity, label: String, ownName: String,
        at: Date? = nil, permit: Permit = .author(.book), revoked: Bool = false
    ) -> PersonRecord {
        let whole = PermitControl.choice(displaying: permit) == .wholeBook
        return PersonRecord(
            person: identity.fingerprint, label: label, ownName: ownName,
            role: permit.wireRole,
            scope: whole ? nil : permit.wireScope,
            pieces: whole ? nil : permit.wirePieces,
            admittedAt: at ?? admitted, admittedBy: mac.fingerprint,
            revokedAt: revoked ? later : nil,
            revokedBy: revoked ? mac.fingerprint : nil)
    }

    /// **The released book's shape.** The root Mac, and its iPhone admitted
    /// under the SAME label with its code for a name and no device record.
    private func denversBook(phoneLabel: String = "Denver Trouton") -> Registry {
        Registry(
            devices: [device(mac, name: "Denver\u{2019}s MacBook Air", kind: .mac)],
            people: [
                person(mac, label: "Denver Trouton",
                       ownName: "Denver\u{2019}s MacBook Air", at: made),
                person(phone, label: phoneLabel,
                       ownName: DeviceCode.short(phone.fingerprint)),
            ])
    }

    private func model(
        _ registry: Registry, unsignedStreams: [String] = []
    ) -> PeopleAndDevicesModel {
        let table = TrustTable.resolve(
            registry: registry, mine: .forAuthor(mac), joinedRoot: nil)
        return PeopleAndDevicesModel.make(
            registry: registry, table: table, remembered: [:],
            requests: [], claimants: [],
            standing: DeviceStanding(
                code: DeviceCode.short(mac.fingerprint), label: "Denver Trouton",
                rootLabel: "Denver Trouton", admitted: true, isRoot: true),
            me: mac.fingerprint, unsignedStreams: unsignedStreams, pieces: pieces)
    }

    // MARK: - 1. One person per label

    /// **Denver's case.** The root's own record and an admitted record under
    /// the same label are ONE person with both machines beneath, marked *you*,
    /// with *this Mac* on the Mac.
    func test_theRootAndAnAdmittedRecordUnderOneLabelAreOnePerson() throws {
        let model = model(denversBook())

        XCTAssertEqual(model.people.count, 2, "premise: two records")
        XCTAssertEqual(model.groups.count, 1, "one writer")
        let denver = try XCTUnwrap(model.groups.first)
        XCTAssertEqual(denver.label, "Denver Trouton")
        XCTAssertEqual(denver.mark, "you")
        XCTAssertEqual(denver.records.map(\.fingerprint),
                       [mac.fingerprint, phone.fingerprint], "the root leads")
        XCTAssertEqual(denver.records[0].devices.map(\.isThisMac), [true])
        XCTAssertNotNil(denver.records[1].unseenDevice,
                        "the phone is a device row, not a second person")
        XCTAssertFalse(denver.permitsDiffer)
        XCTAssertEqual(denver.permitSentence, denver.records[0].permitSentence)
    }

    /// **The converse.** A different label is a different person — and the
    /// rule is `TrustTable.sharesLabel`'s exact strings, so a label differing
    /// only in case is ANOTHER person here, exactly as it is to the label-wide
    /// permit change (the admission merge writes the existing spelling, so a
    /// merged record never differs by case).
    func test_differentLabelsAreDifferentPeople() {
        for other in ["Sam", "denver trouton", ""] {
            let model = model(denversBook(phoneLabel: other))
            XCTAssertEqual(model.groups.count, 2, "\u{201C}\(other)\u{201D}")
            XCTAssertTrue(model.groups.allSatisfy(\.isOneRecord))
        }
    }

    /// Two records with NO label share nothing: *unnamed* is not a person.
    func test_twoUnnamedRecordsAreNeverOnePerson() {
        let registry = Registry(
            devices: [device(mac, name: "Mac", kind: .mac)],
            people: [person(mac, label: "Denver", ownName: "Mac", at: made),
                     person(phone, label: "", ownName: "A"),
                     person(sam, label: "", ownName: "B")])
        XCTAssertEqual(model(registry).groups.count, 3)
    }

    /// **Change… is the person's, and refused where a root is among them.**
    /// The label-wide verb asks every record under the label, and a root's
    /// answer is always no — so Denver's group draws no Change… at all, while
    /// an admitted writer's two machines draw one, on the person.
    func test_changeIsOnThePersonAndAbsentWhereTheRootIsOneOfThem() throws {
        let denver = try XCTUnwrap(model(denversBook()).groups.first)
        XCTAssertFalse(denver.offersPermitChange,
                       "the root's own record is under this label")

        let registry = Registry(
            devices: [device(mac, name: "Mac", kind: .mac),
                      device(sam, name: "Sam's Mac", kind: .mac),
                      device(samsPhone, name: "Sam's iPhone", kind: .phone)],
            people: [person(mac, label: "Denver", ownName: "Mac", at: made),
                     person(sam, label: "Sam", ownName: "Sam's Mac"),
                     person(samsPhone, label: "Sam", ownName: "Sam's iPhone",
                            at: later)])
        let samGroup = try XCTUnwrap(model(registry).groups.first { $0.label == "Sam" })
        XCTAssertEqual(samGroup.records.count, 2)
        XCTAssertTrue(samGroup.offersPermitChange)
        XCTAssertTrue(samGroup.canChangePermit, samGroup.whyNotChangeable ?? "")
        XCTAssertEqual(samGroup.changeSubject.fingerprint, sam.fingerprint)
        XCTAssertEqual(samGroup.records.map { $0.devices.first?.kind }, ["Mac", "iPhone"])
    }

    /// **Legacy: two records under one label holding different permits.** The
    /// person says they differ; each device row says its own. And the
    /// converse: agreeing permits are said once, on the person.
    func test_differingPermitsAreSaidOnTheDeviceRows() throws {
        func samGroup(phonePermit: Permit, revoked: Bool = false) throws
            -> PeopleAndDevicesModel.PersonGroup {
            let registry = Registry(
                devices: [device(mac, name: "Mac", kind: .mac)],
                people: [person(mac, label: "Denver", ownName: "Mac", at: made),
                         person(sam, label: "Sam", ownName: "Sam's Mac",
                                permit: .author(.pieces(["ch4"]))),
                         person(samsPhone, label: "Sam", ownName: "Sam's iPhone",
                                at: later, permit: phonePermit, revoked: revoked)])
            return try XCTUnwrap(model(registry).groups.first { $0.label == "Sam" })
        }

        let differ = try samGroup(phonePermit: .reviewer)
        XCTAssertTrue(differ.permitsDiffer)
        XCTAssertEqual(differ.permitSentence,
                       PeopleAndDevicesModel.PersonGroup.permitsDifferSentence)
        XCTAssertNotEqual(differ.records[0].permitSentence,
                          differ.records[1].permitSentence,
                          "each device row says its own")

        let agree = try samGroup(phonePermit: .author(.pieces(["ch4"])))
        XCTAssertFalse(agree.permitsDiffer)
        XCTAssertEqual(agree.permitSentence, agree.records[0].permitSentence)
        XCTAssertTrue(agree.permitSentence.contains("Chapter 4"), agree.permitSentence)

        // A REVOKED machine's old permit is not a disagreement: its lines are
        // refused by the verdict whatever it says.
        let revoked = try samGroup(phonePermit: .reviewer, revoked: true)
        XCTAssertFalse(revoked.permitsDiffer)
        XCTAssertEqual(revoked.changeSubject.fingerprint, sam.fingerprint,
                       "Change… is asked about a live record")
    }

    // MARK: - 2. A record with no device record

    /// **It is a device row, named by the record and claiming no kind** — and
    /// where a device record exists, there is no such row.
    func test_aRecordWithNoDeviceRecordIsAnUnseenDeviceThatClaimsNoKind() throws {
        let denver = try XCTUnwrap(model(denversBook()).groups.first)
        let code = DeviceCode.short(phone.fingerprint)

        let unseen = try XCTUnwrap(denver.records[1].unseenDevice)
        XCTAssertEqual(unseen.title, code,
                       "a name that IS the code is said once, not *0ECB (0ECB)*")
        XCTAssertFalse(unseen.isThisMac)
        for sentence in [unseen.title, PeopleAndDevicesModel.UnseenDevice.sentence] {
            XCTAssertFalse(sentence.contains("iPhone"), sentence)
            XCTAssertFalse(sentence.contains("Mac "), sentence)
        }
        XCTAssertTrue(PeopleAndDevicesModel.UnseenDevice.sentence
            .contains("by the next time the device writes"),
            "true of a Mac (writes it at open) and a phone (at a write)")
        XCTAssertFalse(PeopleAndDevicesModel.UnseenDevice.sentence
            .contains("when it opens"), "false of the phone")
        XCTAssertNil(denver.records[0].unseenDevice,
                     "the Mac has a device record, and draws it")
        XCTAssertEqual(denver.records[1].title, "Denver Trouton",
                       "no code in brackets on the person either")
    }

    // MARK: - 3. Pre-signing history is one quiet line

    private var signingEraSlug: String {
        DeviceSlug.make(from: DeviceIdentity.deviceId(
            actor: DeviceActor.author.rawValue, fingerprint: sam.fingerprint)).raw
    }

    /// The five legacy spellings a pre-P1 book holds, as `readUnsigned` names
    /// them: a Mac under its hostname, the MCP and rebalance sentinels, a
    /// phone's `phone:<uuid>` inbox, and every unsuffixed file.
    private var legacyStreams: [String] {
        ["Denvers-MacBook-Air.local", "mcp", "rebalance",
         "phone:18B59020-1A2B-4C3D-8E9F-0123456789AB"]
            .map { DeviceSlug.make(from: $0).raw }
            + [HeldLines.oldestHistoryStream]
    }

    /// **Legacy streams collapse into ONE row, described in the writer's
    /// words; a signing-era stream keeps today's row.**
    func test_olderHistoryIsOneRowAndASigningEraStreamKeepsItsOwn() throws {
        let model = model(denversBook(),
                          unsignedStreams: legacyStreams + [signingEraSlug])

        XCTAssertEqual(model.unsigned.map(\.stream), [signingEraSlug],
                       "the case the existing sentence was written for, unchanged")
        let older = try XCTUnwrap(model.olderHistory)
        XCTAssertEqual(older.sources.count, 5, "\(older.sources)")
        XCTAssertTrue(older.sources.contains("edits made through MCP"))
        XCTAssertTrue(older.sources.contains("the task rebalance"))
        XCTAssertTrue(older.sources.contains {
            $0.contains("denvers-macbook-air-loca") }, "\(older.sources)")
        XCTAssertTrue(older.sources.contains { $0.contains("phone") })
        XCTAssertTrue(older.sources.contains { $0.contains("oldest history") })
    }

    /// The converse, twice: a book with only signing-era streams draws no
    /// older-history row, and a book with only older history draws no
    /// *Nothing this book holds says who signs for …* row at all.
    func test_eachKindOfStreamDrawsOnlyItsOwnRow() {
        let signing = model(denversBook(), unsignedStreams: [signingEraSlug])
        XCTAssertNil(signing.olderHistory)
        XCTAssertEqual(signing.unsigned.count, 1)

        let legacy = model(denversBook(), unsignedStreams: legacyStreams)
        XCTAssertNotNil(legacy.olderHistory)
        XCTAssertTrue(legacy.unsigned.isEmpty,
                      "no warning per stream about the writer's own old work")
    }

    /// **Un-narrowed says nothing will change; narrowed says what the
    /// photograph kept.** Both say what is TRUE of lines already there
    /// (applied), and neither promises anything about a Mac.
    func test_theOlderHistorySentenceFollowsTheBooksNarrowing() {
        let before = PeopleAndDevicesModel.OlderHistory.beforeNarrowing
        let after = PeopleAndDevicesModel.OlderHistory.afterNarrowing
        XCTAssertTrue(before.hasPrefix("Nothing already in it will change."), before)
        XCTAssertTrue(before.contains("anything an older version"),
                      "a later line from an older build is not promised: \(before)")
        XCTAssertTrue(before.contains("stays applied"), before)
        XCTAssertTrue(after.contains("stays applied"), after)
        XCTAssertTrue(after.contains("anything an older version"), after)
        for sentence in [before, after] {
            XCTAssertFalse(sentence.contains("who signs for"), sentence)
            XCTAssertFalse(sentence.localizedCaseInsensitiveContains("enclave"), sentence)
        }
        XCTAssertFalse(model(denversBook(), unsignedStreams: legacyStreams).alreadyNarrowed,
                       "premise: Denver's book is narrowed in nobody")
    }

    /// **A document id is never presented as a signer.** Every unsuffixed file
    /// reaches a surface as `HeldLines.oldestHistoryStream`, and nothing the
    /// pane says about unsigned streams carries a `doc-` name.
    func test_noDocumentIdIsEverAStreamName() throws {
        let model = model(denversBook(), unsignedStreams: legacyStreams)
        let said = model.unsigned.map(\.sentence)
            + (model.olderHistory?.sources ?? [])
        XCTAssertFalse(said.isEmpty)
        for sentence in said {
            XCTAssertFalse(sentence.contains("doc-"), sentence)
            XCTAssertFalse(sentence.contains(HeldLines.oldestHistoryStream), sentence)
        }
    }
}

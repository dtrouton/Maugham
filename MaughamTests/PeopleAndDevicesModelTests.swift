import XCTest
@testable import Maugham
@testable import MaughamCore

/// **Who may write in this book, on which devices, and what is waiting**
/// (signed op log P2, spec §6).
///
/// Everything the section shows is decided here, as a value over a registry,
/// a trust table, this device's memory and the held-line counts — so the rows,
/// the marks and the refusal are all assertable with nothing mounted. The
/// section's own suite asserts only that they reach the screen.
@MainActor
final class PeopleAndDevicesModelTests: XCTestCase {

    private var mac: DeviceIdentity!
    private var phone: DeviceIdentity!
    private var stranger: DeviceIdentity!
    private var otherRoot: DeviceIdentity!

    override func setUp() async throws {
        mac = .softwareForTesting()
        phone = .softwareForTesting()
        stranger = .softwareForTesting()
        otherRoot = .softwareForTesting()
    }

    // MARK: - Fixture

    private let admitted = Date(timeIntervalSince1970: 1_757_000_000)
    private let made = Date(timeIntervalSince1970: 1_756_000_000)

    private func deviceRecord(
        _ identity: DeviceIdentity, name: String, kind: DeviceKind = .phone,
        actors: [DeviceActor] = [.author], retiredAt: Date? = nil
    ) -> DeviceRecord {
        var keys: [String: String] = [:]
        for actor in actors {
            keys[actor.rawValue] = actor == .author
                ? identity.fingerprint
                : "\(actor.rawValue)-key-\(identity.fingerprint.prefix(8))"
        }
        return DeviceRecord(
            device: identity.fingerprint, name: name, kind: kind,
            actors: keys, madeAt: made, retiredAt: retiredAt)
    }

    private func person(
        _ identity: DeviceIdentity, label: String, ownName: String,
        admittedBy: DeviceIdentity, revoked: Bool = false
    ) -> PersonRecord {
        PersonRecord(
            person: identity.fingerprint, label: label, ownName: ownName,
            role: "author", admittedAt: admitted, admittedBy: admittedBy.fingerprint,
            revokedAt: revoked ? admitted.addingTimeInterval(86_400) : nil,
            revokedBy: revoked ? mac.fingerprint : nil)
    }

    /// This Mac is the root and has admitted the phone; a stranger has a
    /// device record and no admission.
    private func registry(revoked: Bool = false) -> Registry {
        Registry(
            devices: [
                deviceRecord(mac, name: "Denver's MacBook", kind: .mac,
                             actors: [.author, .assistant]),
                deviceRecord(phone, name: "Denver's iPhone"),
                deviceRecord(stranger, name: "The old iPhone"),
            ],
            people: [
                person(mac, label: "Denver", ownName: "Denver's MacBook", admittedBy: mac),
                person(phone, label: "Denver", ownName: "Denver's iPhone",
                       admittedBy: mac, revoked: revoked),
            ])
    }

    private func table(_ registry: Registry) -> TrustTable {
        TrustTable.resolve(registry: registry, mine: .forAuthor(mac), joinedRoot: nil)
    }

    private func standing() -> DeviceStanding {
        DeviceStanding(
            code: DeviceCode.short(mac.fingerprint), label: "Denver",
            rootLabel: "Denver", admitted: true, isRoot: true)
    }

    private func model(
        _ registry: Registry,
        remembered: [String: AdmissionMemory.Label] = [:],
        pending: [String: Int] = [:],
        claimants: [String] = [],
        restores: [RestoredRecord] = [],
        restorable: Set<RecordRef> = [],
        table overrideTable: TrustTable? = nil
    ) -> PeopleAndDevicesModel {
        let table = overrideTable ?? table(registry)
        return PeopleAndDevicesModel.make(
            registry: registry, table: table,
            remembered: remembered,
            // The counts go through the SAME derivation the admission sheet
            // queues (Task 7): who is a stranger with lines waiting is decided
            // once, and this pane draws that decision rather than a second one.
            requests: AdmissionDecision.requests(
                pending: pending, registry: registry,
                memory: remembered, myRoot: table.myRoot),
            claimants: claimants,
            restores: restores,
            restorable: restorable,
            standing: standing(), me: mac.fingerprint)
    }

    // MARK: - Records that don't verify (P2 smoke find 1)

    /// **A record the reader refuses contributes nothing and, until this,
    /// appeared nowhere.** Its consequences were loud — a tampered root record
    /// had this Mac reading as *not yet admitted* on its own book — and its
    /// cause was invisible. The row names the file, says which of the three
    /// kinds it is, and gives the reader's own sentence for what is wrong.
    func test_arecordThatDoesNotVerifyIsListedWithTheReadersOwnReason() throws {
        let damaged = Registry(
            devices: registry().devices, people: registry().people,
            malformed: [MalformedRecord(
                url: URL(fileURLWithPath:
                    "/Book/.maugham/people/\(stranger.fingerprint).json"),
                reason: .signatureDoesNotVerify)])
        let model = model(damaged)

        let row = try XCTUnwrap(model.unverifiable.first)
        XCTAssertEqual(model.unverifiable.count, 1)
        XCTAssertEqual(row.ref,
                       RecordRef(directory: .people, fingerprint: stranger.fingerprint))
        XCTAssertEqual(row.kind, "person")
        XCTAssertEqual(row.code, DeviceCode.short(stranger.fingerprint))
        XCTAssertTrue(row.sentence.contains("was changed after it was signed"),
                      "the reader's vocabulary, not a second one: \(row.sentence)")
        XCTAssertFalse(row.isMine)
        XCTAssertFalse(row.canRestore, "nothing remembered, so nothing to put back")
    }

    /// The row says when the record is this Mac's own — the header above it can
    /// only say what this device's standing IS, and this row is the reason.
    func test_thismacsOwnUnverifiableRecordSaysSoOnItsRow() throws {
        let damaged = Registry(
            devices: registry().devices, people: registry().people,
            malformed: [MalformedRecord(
                url: URL(fileURLWithPath:
                    "/Book/.maugham/people/\(mac.fingerprint).json"),
                reason: .unsigned)])

        let row = try XCTUnwrap(model(damaged).unverifiable.first)
        XCTAssertTrue(row.isMine)
    }

    /// Restore is offered only where this Mac still holds the bytes that last
    /// verified — and the row is listed either way, because naming the file is
    /// the whole point of the section.
    func test_restoreIsOfferedOnlyWhereThisMacRemembersAVersionThatVerified() throws {
        let people = RecordRef(directory: .people, fingerprint: phone.fingerprint)
        let devices = RecordRef(directory: .devices, fingerprint: stranger.fingerprint)
        let damaged = Registry(
            devices: registry().devices, people: registry().people,
            malformed: [
                MalformedRecord(
                    url: URL(fileURLWithPath:
                        "/Book/.maugham/people/\(phone.fingerprint).json"),
                    reason: .signatureDoesNotVerify),
                MalformedRecord(
                    url: URL(fileURLWithPath:
                        "/Book/.maugham/devices/\(stranger.fingerprint).json"),
                    reason: .unsigned),
            ])

        let model = model(damaged, restorable: [people])

        XCTAssertEqual(model.unverifiable.count, 2)
        let remembered = try XCTUnwrap(model.unverifiable.first { $0.ref == people })
        let forgotten = try XCTUnwrap(model.unverifiable.first { $0.ref == devices })
        XCTAssertTrue(remembered.canRestore)
        XCTAssertEqual(remembered.kind, "person")
        XCTAssertFalse(forgotten.canRestore)
        XCTAssertEqual(forgotten.kind, "device")
    }

    /// A file that is not in one of the registry's three directories names no
    /// record, so there is nothing to list and nothing to put back.
    func test_afileOutsideTheRegistrysDirectoriesIsNotARow() {
        let damaged = Registry(
            devices: registry().devices, people: registry().people,
            malformed: [MalformedRecord(
                url: URL(fileURLWithPath: "/Book/.maugham/notes/whatever.json"),
                reason: .unsigned)])

        XCTAssertTrue(model(damaged).unverifiable.isEmpty)
    }

    // MARK: - A record somebody deleted is marked (P2b Task 10)

    /// **The row says the record was put back.** A restoration leaves nothing
    /// in the folder afterwards — the file is back, and looks exactly as it did
    /// before somebody deleted it — so this mark is the only thing on this
    /// screen that says the book's chain was interfered with. It reads the SAME
    /// dated list History dates its own event from.
    func test_aRestoredPersonRecordIsMarkedOnItsRow() throws {
        let when = Date(timeIntervalSince1970: 900)
        let model = model(registry(), restores: [
            RestoredRecord(
                ref: RecordRef(directory: .people, fingerprint: phone.fingerprint),
                restoredAt: when)
        ])

        let row = try XCTUnwrap(model.people.first { $0.fingerprint == self.phone.fingerprint })
        XCTAssertEqual(row.restoredAt, when)
        XCTAssertTrue(row.detail.contains("put back"),
                      "and the row says so: \(row.detail)")

        let untouched = try XCTUnwrap(model.people.first { $0.fingerprint == self.mac.fingerprint })
        XCTAssertNil(untouched.restoredAt,
                     "a record nobody deleted carries no mark")
        XCTAssertFalse(untouched.detail.contains("put back"))
    }

    /// The newest restoration is the one a ROW shows: a row is a state, and a
    /// record put back twice is one record with a most-recent day. History is
    /// where both events are.
    func test_aRecordPutBackTwiceShowsTheNewerDay() throws {
        let ref = RecordRef(directory: .people, fingerprint: phone.fingerprint)
        let model = model(registry(), restores: [
            RestoredRecord(ref: ref, restoredAt: Date(timeIntervalSince1970: 900)),
            RestoredRecord(ref: ref, restoredAt: Date(timeIntervalSince1970: 1_900)),
        ])

        let row = try XCTUnwrap(model.people.first { $0.fingerprint == self.phone.fingerprint })
        XCTAssertEqual(row.restoredAt, Date(timeIntervalSince1970: 1_900))
    }

    // MARK: - Pending requests come first

    /// The one row that asks the writer for something, and it is at the top
    /// because everything below it is a fact and this is a question.
    func test_apendingDeviceIsListedFirstWithWhatItIsWaitingOn() throws {
        let model = model(registry(), pending: [stranger.fingerprint: 14])

        XCTAssertEqual(model.pending.count, 1)
        let request = try XCTUnwrap(model.pending.first)
        XCTAssertEqual(request.name, "The old iPhone")
        XCTAssertEqual(request.code, DeviceCode.short(stranger.fingerprint))
        XCTAssertEqual(request.heldLines, 14)
        XCTAssertTrue(request.sentence.contains("14"),
                      "the count is in the sentence: \(request.sentence)")
    }

    /// **The pending row says what the sheet says** (P3b smoke F2): paragraphs
    /// in a piece by title, not a line count.
    func test_apendingRowSaysWhatIsWaitingAndWhere() throws {
        let registry = registry()
        let model = PeopleAndDevicesModel.make(
            registry: registry, table: table(registry), remembered: [:],
            requests: AdmissionDecision.requests(
                pending: [stranger.fingerprint: 1], registry: registry,
                memory: [:], myRoot: table(registry).myRoot),
            claimants: [], standing: standing(), me: mac.fingerprint,
            held: [stranger.fingerprint: 1],
            pieces: [PermitControl.Piece(id: "doc-3", title: "Chapter 3")],
            heldWaiting: [stranger.fingerprint: ["doc-3": HeldLines.Waiting(
                paragraphIds: ["p1ab"], prose: 1)]])

        let row = try XCTUnwrap(model.pending.first)
        XCTAssertEqual(row.sentence,
                       "The old iPhone (\(row.code)) — 1 paragraph waiting in “Chapter 3”")
    }

    /// **A stranger's record with nothing held is a pending row too** (P3b
    /// smoke F10), in the sheet's own words — never *0 lines waiting*. The
    /// fixture's old iPhone has a device record and no admission, and nothing
    /// of it is held.
    func test_aRecordOnlyStrangerIsPendingAndSaysNothingHasReachedThisMac() throws {
        let model = model(registry())

        let row = try XCTUnwrap(model.pending.first)
        XCTAssertEqual(model.pending.map(\.fingerprint), [stranger.fingerprint])
        XCTAssertEqual(row.heldLines, 0)
        XCTAssertEqual(row.sentence,
                       "The old iPhone (\(row.code)) — Nothing from it has reached this Mac yet.")
        XCTAssertFalse(row.sentence.contains("0 lines"), row.sentence)
    }

    /// And the held one first: a stranger whose words are here is the one the
    /// writer is asked about first.
    func test_aStrangerHoldingLinesIsListedBeforeARecordOnlyOne() {
        let unknown = DeviceIdentity.softwareForTesting()
        let model = model(registry(), pending: [unknown.fingerprint: 1])

        XCTAssertEqual(model.pending.map(\.fingerprint),
                       [unknown.fingerprint, stranger.fingerprint])
    }

    /// A device with nothing on disk to describe it is named by its code — the
    /// four characters its own Settings screen shows, which is the whole of
    /// how an admission is checked.
    func test_apendingDeviceWithNoRecordIsNamedByItsCode() {
        let unknown = DeviceIdentity.softwareForTesting()
        let model = model(registry(), pending: [unknown.fingerprint: 3])

        XCTAssertEqual(model.pending.first?.name, DeviceCode.short(unknown.fingerprint))
    }

    /// **An admitted device is never pending, whatever a stale count says.**
    /// The counts come from the last read; the verdicts come from the registry
    /// as it stands now, and admitting somebody must take their row away rather
    /// than leave the writer a button that would do nothing.
    func test_acountForAnAdmittedDeviceRaisesNoRequest() {
        let model = model(registry(), pending: [phone.fingerprint: 9,
                                                mac.fingerprint: 2])

        let pending = model.pending.map(\.fingerprint)
        XCTAssertFalse(pending.contains(phone.fingerprint),
                       "the phone is admitted: \(model.pending)")
        XCTAssertFalse(pending.contains(mac.fingerprint),
                       "the Mac is this device: \(model.pending)")
        // F10: the fixture's unadmitted old iPhone has a record and no lines,
        // and a stranger's record alone is now somebody to ask about.
        XCTAssertEqual(pending, [stranger.fingerprint])
    }

    // MARK: - One row per person, devices nested

    func test_eachAdmittedPersonIsOneRowCarryingTheirDevices() throws {
        let model = model(registry())

        XCTAssertEqual(model.people.map(\.label), ["Denver", "Denver"])
        let phoneRow = try XCTUnwrap(
            model.people.first { $0.fingerprint == phone.fingerprint })
        XCTAssertEqual(phoneRow.role, "author")
        XCTAssertEqual(phoneRow.devices.map(\.name), ["Denver's iPhone"])
        XCTAssertEqual(phoneRow.devices.first?.kind, "iPhone")
    }

    /// The device's own name is shown beside the label whenever the two differ
    /// — a writer who called both machines "Denver" needs to know which is
    /// which before they revoke one.
    /// **The bracketed name is dropped where a device row beneath already says
    /// it** (Denver's re-smoke, 2026-09-19). Under P2 a person IS one device,
    /// so this is every ordinary row: *Denver Trouton (Denver's MacBook Air) ·
    /// you* sat directly above *Denver's MacBook Air · this Mac*, which is the
    /// same words twice in two lines.
    func test_thebracketedNameIsDroppedWhenADeviceRowBeneathAlreadySaysIt() throws {
        let model = model(registry())
        let phoneRow = try XCTUnwrap(
            model.people.first { $0.fingerprint == phone.fingerprint })

        XCTAssertTrue(phoneRow.devices.contains { $0.name == "Denver's iPhone" },
                      "premise: the machine is named on the row beneath")
        XCTAssertNil(phoneRow.ownName)
        XCTAssertEqual(phoneRow.title, "Denver")
    }

    /// **And kept where nothing beneath can say it.** A person the book holds
    /// no device record for draws no nested row, so the label would stand alone
    /// and a writer who called two machines "Denver" could not tell which one
    /// they were about to revoke — which is what the brackets were for.
    func test_thebracketedNameIsKeptWhenNoDeviceRowShowsIt() throws {
        let noDeviceRecord = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac)],
            people: [
                person(mac, label: "Denver", ownName: "Denver's MacBook",
                       admittedBy: mac),
                person(phone, label: "Denver", ownName: "Denver's iPhone",
                       admittedBy: mac),
            ])
        let model = model(noDeviceRecord)

        let phoneRow = try XCTUnwrap(
            model.people.first { $0.fingerprint == phone.fingerprint })
        XCTAssertTrue(phoneRow.devices.isEmpty, "premise: nothing beneath names it")
        XCTAssertEqual(phoneRow.ownName, "Denver's iPhone")
        XCTAssertEqual(phoneRow.title, "Denver (Denver's iPhone)")
    }

    func test_alabelThatAlreadyIsTheDevicesOwnNameIsNotRepeated() throws {
        let same = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac)],
            people: [person(mac, label: "Denver's MacBook",
                            ownName: "Denver's MacBook", admittedBy: mac)])
        let model = model(same)

        XCTAssertNil(model.people.first?.ownName)
        XCTAssertEqual(model.people.first?.title, "Denver's MacBook")
    }

    /// Every actor the device holds, as words. A writer looking at what a
    /// machine may write in their book is owed the four writers by name, not a
    /// count of keys.
    func test_adeviceListsTheActorsItHoldsAsWords() throws {
        let model = model(registry())
        let macRow = try XCTUnwrap(model.people.first { $0.fingerprint == mac.fingerprint })

        XCTAssertEqual(macRow.devices.first?.actors, ["author", "assistant"],
                       "in the order the enum declares them")
    }

    func test_thisMacsOwnDeviceIsMarked() throws {
        let model = model(registry())
        let macRow = try XCTUnwrap(model.people.first { $0.fingerprint == mac.fingerprint })
        let phoneRow = try XCTUnwrap(model.people.first { $0.fingerprint == phone.fingerprint })

        XCTAssertTrue(macRow.devices.first?.isThisMac == true)
        XCTAssertFalse(phoneRow.devices.first?.isThisMac == true)
    }

    /// **The root's own row says *you*, and the badge that says *this Mac* is
    /// the DEVICE row's** (P2 smoke find 2). One Mac used to read as three —
    /// a header naming the machine, a person row marked *this Mac*, and the
    /// device row nested under it marked *this Mac* again — with nothing on the
    /// screen distinguishing the writer from the laptop.
    func test_therootsOwnRowSaysYouAndTheMachineBadgeIsTheDevicesAlone() throws {
        let model = model(registry())
        let macRow = try XCTUnwrap(model.people.first { $0.fingerprint == mac.fingerprint })

        XCTAssertEqual(macRow.mark, "you")
        XCTAssertTrue(macRow.devices.contains { $0.isThisMac },
                      "the machine is named on the row that is a machine")
        XCTAssertNil(model.people.first { $0.fingerprint == phone.fingerprint }?.mark)
    }

    /// A root is claimed over, never revoked — on every folder, on every day —
    /// so its row draws no Revoke at all. Elsewhere a refused verb keeps its
    /// disabled button and says why; a disabled button is an offer with a
    /// condition on it, and here there is no condition.
    func test_arootsRowOffersNoRevokeAtAll() throws {
        let model = model(registry())
        let root = try XCTUnwrap(model.people.first { $0.fingerprint == mac.fingerprint })
        let admitted = try XCTUnwrap(
            model.people.first { $0.fingerprint == phone.fingerprint })

        XCTAssertFalse(root.offersRevoke)
        XCTAssertTrue(admitted.offersRevoke,
                      "everyone the root admitted still carries the verb")
    }

    // MARK: - Rename (P2 smoke find 3)

    /// **A label could be chosen once and never corrected.** This Mac may
    /// rename everybody it admitted — and its own root row, which is the row
    /// the smoke was about: a root record names ITSELF as its admitter, so the
    /// one rule covers both without a clause of its own.
    func test_thismacRenamesEveryoneItAdmittedAndItself() throws {
        let model = model(registry())
        let root = try XCTUnwrap(model.people.first { $0.fingerprint == mac.fingerprint })
        let admitted = try XCTUnwrap(
            model.people.first { $0.fingerprint == phone.fingerprint })

        XCTAssertTrue(root.canRename, "a root renames itself")
        XCTAssertNil(root.whyNotRenamable)
        XCTAssertTrue(admitted.canRename)
        XCTAssertNil(admitted.whyNotRenamable)
    }

    /// A Mac standing in somebody else's chain renames nobody, and the verb
    /// refuses it one guard earlier than the pane used to look (whole-branch
    /// review, Minor 1).
    ///
    /// **The sentence changed here, deliberately.** This used to read *only the
    /// Mac that admitted this device can rename it* — true of each row, and a
    /// poor account of what the writer is looking at, which is a pane where
    /// every Rename is dead for one reason: this Mac holds no root record in
    /// this book, so nothing it signs would stand. `RegistryAdmission.rename`
    /// has always refused it on that ground first; only the pane had the two
    /// guards in the other order, and it had the outer one not at all.
    func test_amacOnSomebodyElsesChainRenamesNobodyAndSaysWhy() throws {
        let joined = Registry(
            devices: [deviceRecord(otherRoot, name: "Amelia's MacBook", kind: .mac),
                      deviceRecord(mac, name: "Denver's MacBook", kind: .mac),
                      deviceRecord(phone, name: "Denver's iPhone")],
            people: [person(otherRoot, label: "Amelia", ownName: "Amelia's MacBook",
                            admittedBy: otherRoot),
                     person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: otherRoot),
                     person(phone, label: "Denver", ownName: "Denver's iPhone",
                            admittedBy: otherRoot)])
        let model = model(joined)

        for fingerprint in [otherRoot.fingerprint, phone.fingerprint] {
            let row = try XCTUnwrap(model.people.first { $0.fingerprint == fingerprint })
            XCTAssertFalse(row.canRename)
            XCTAssertEqual(row.whyNotRenamable, PeopleAndDevicesModel.renameNotARoot)
        }
    }

    /// The other refusal, so the two are pinned apart and neither sentence can
    /// rot: this Mac IS the root here, and the row belongs to somebody its own
    /// phone admitted. Renaming that record would be re-signing a record signed
    /// by a key that is not this Mac's, which is Revoke's rule exactly.
    func test_arowAdmittedBySomebodyIAdmittedIsNotMineToRename() throws {
        let twoDeep = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac),
                      deviceRecord(phone, name: "Denver's iPhone"),
                      deviceRecord(stranger, name: "The old iPhone")],
            people: [person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: mac),
                     person(phone, label: "Denver", ownName: "Denver's iPhone",
                            admittedBy: mac),
                     person(stranger, label: "Rosa", ownName: "The old iPhone",
                            admittedBy: phone)])

        let row = try XCTUnwrap(
            model(twoDeep).people.first { $0.fingerprint == stranger.fingerprint })

        XCTAssertFalse(row.canRename)
        // **Where, not why** (Denver's wording ruling, 2026-09-18): the refusal
        // names the Mac the book was started on, which is the one thing the
        // writer can act on. Here that is the phone's own admitter, this Mac's
        // label — "Denver".
        let refusal = try XCTUnwrap(row.whyNotRenamable)
        XCTAssertEqual(refusal,
                       PeopleAndDevicesModel.renameNotMine(startedOn: "Denver"))
        XCTAssertTrue(refusal.contains("started"),
                      "in the writer's frame: \(refusal)")
    }

    /// **The pane's rule is the verb's rule, root guard included**
    /// (whole-branch review, Minor 1).
    ///
    /// `RegistryAdmission.rename` refuses a signer that is not a root of this
    /// book BEFORE it looks at who admitted whom — a rename RE-SIGNS the
    /// record, and a signature from a Mac no root record names is one every
    /// reader lists as malformed. The pane asked only the second question
    /// (`record.admittedBy == me`), so a row could be drawn with a live Rename
    /// that the verb would throw on.
    ///
    /// **The shape, and its honest reachability.** `Registry.chain(underRoot:)`
    /// is transitive, so a person admitted by somebody who was themselves
    /// admitted is drawn on this pane — and for that row `admittedBy` can be
    /// this Mac while this Mac holds no root record. `RegistryReader` cannot
    /// produce that today: it refuses a non-root person record whose
    /// `admittedBy` is not a verified root, which makes `admittedBy == me`
    /// imply *me is a root* for every record it hands over. So the old rule was
    /// not wrong for any registry the pipeline builds — it was right by
    /// borrowing an invariant three files away, and it is the day a non-root
    /// may admit that the borrowing costs the writer a button that throws. The
    /// model takes a `Registry` value, so the disagreement is constructible
    /// here even though the folder cannot yet hold it.
    func test_theRenameRuleIsTheVerbsIncludingTheRootGuardThePaneUsedToSkip() throws {
        // Amelia roots and admitted this Mac; this Mac admitted the phone.
        let twoDeep = Registry(
            devices: [deviceRecord(otherRoot, name: "Amelia's MacBook", kind: .mac),
                      deviceRecord(mac, name: "Denver's MacBook", kind: .mac),
                      deviceRecord(phone, name: "Denver's iPhone")],
            people: [person(otherRoot, label: "Amelia", ownName: "Amelia's MacBook",
                            admittedBy: otherRoot),
                     person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: otherRoot),
                     person(phone, label: "Denver", ownName: "Denver's iPhone",
                            admittedBy: mac)])

        guard case .failure(.notARoot) = RegistryAdmission.renameOutcome(
            person: phone.fingerprint, by: mac.fingerprint, in: twoDeep)
        else {
            return XCTFail("premise: the verb refuses this, so no button can work")
        }
        let row = try XCTUnwrap(
            model(twoDeep).people.first { $0.fingerprint == phone.fingerprint })

        XCTAssertFalse(row.canRename,
                       "the row's own admitter IS this Mac, which is all the pane "
                           + "used to ask — and the verb would still have thrown")
        XCTAssertEqual(row.whyNotRenamable, PeopleAndDevicesModel.renameNotARoot)
    }

    /// A root somebody else owns, whose chain this device joined: it is still
    /// the root, and saying "this Mac" of it would be a lie about whose machine
    /// holds the book.
    func test_aforeignRootIsMarkedByWhoseMacItIs() throws {
        let joined = Registry(
            devices: [deviceRecord(otherRoot, name: "Amelia's MacBook", kind: .mac),
                      deviceRecord(mac, name: "Denver's MacBook", kind: .mac)],
            people: [person(otherRoot, label: "Amelia", ownName: "Amelia's MacBook",
                            admittedBy: otherRoot),
                     person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: otherRoot)])
        let model = model(joined)

        let rootRow = try XCTUnwrap(
            model.people.first { $0.fingerprint == otherRoot.fingerprint })
        XCTAssertEqual(rootRow.mark, "Amelia\u{2019}s Mac")
    }

    func test_arevokedPersonSaysSoAndKeepsTheirRow() throws {
        let model = model(registry(revoked: true))
        let phoneRow = try XCTUnwrap(
            model.people.first { $0.fingerprint == phone.fingerprint })

        XCTAssertNotNil(phoneRow.revokedAt)
        XCTAssertTrue(phoneRow.detail.lowercased().contains("revoked"),
                      "the row says what happened: \(phoneRow.detail)")
    }

    // MARK: - Who may revoke, and who may retire (P2b Task 7, spec §5)

    /// **Only the root that admitted them.** A person record is signed by the
    /// root it names, so a Mac that is not that root would write a file every
    /// reader lists as malformed — a device un-admitted in silence rather than
    /// revoked.
    func test_thedeviceThisMacAdmittedMayBeRevoked() throws {
        let model = model(registry())
        let person = try XCTUnwrap(model.people.first { $0.fingerprint == phone.fingerprint })

        XCTAssertTrue(person.canRevoke)
        XCTAssertNil(person.whyNotRevocable)
    }

    /// A root answers to itself: it is claimed over, never revoked (spec §5).
    func test_arootIsNotRevocableAndSaysWhy() throws {
        let model = model(registry())
        let root = try XCTUnwrap(model.people.first { $0.fingerprint == mac.fingerprint })

        XCTAssertFalse(root.canRevoke)
        XCTAssertEqual(root.whyNotRevocable, PeopleAndDevicesModel.revokeARoot)
    }

    /// Revoking twice would move the line the first revocation drew, so the
    /// second press is refused before it is offered.
    func test_analreadyRevokedPersonIsNotRevokedAgain() throws {
        let model = model(registry(revoked: true))
        let person = try XCTUnwrap(model.people.first { $0.fingerprint == phone.fingerprint })

        XCTAssertFalse(person.canRevoke)
        XCTAssertEqual(person.whyNotRevocable, PeopleAndDevicesModel.alreadyRevoked)
    }

    /// **A person somebody else's root admitted is their record to change.**
    ///
    /// The case is this Mac having JOINED another root's chain: everyone on it
    /// is listed here, because they are who may write in this book, and the
    /// records are signed by the root that admitted them — so revoking one from
    /// here would write a file every reader lists as malformed. A person under
    /// a root this Mac is NOT on is a different thing again: they are not in
    /// this Mac's chain, so they are not a row at all, and the claimant line
    /// above is what says so.
    func test_apersonAdmittedByAnotherRootIsNotThisMacsToRevoke() throws {
        let registry = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac),
                      deviceRecord(phone, name: "Denver's iPhone")],
            people: [person(otherRoot, label: "Amelia", ownName: "Amelia's MacBook",
                            admittedBy: otherRoot),
                     person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: otherRoot),
                     person(phone, label: "Denver", ownName: "Denver's iPhone",
                            admittedBy: otherRoot)])
        let table = TrustTable.resolve(
            registry: registry, mine: .forAuthor(mac), joinedRoot: nil)
        XCTAssertEqual(table.myRoot, otherRoot.fingerprint,
                       "this Mac is on somebody else's chain")

        let model = PeopleAndDevicesModel.make(
            registry: registry, table: table, remembered: [:], requests: [],
            claimants: [], standing: standing(), me: mac.fingerprint)

        let theirs = try XCTUnwrap(
            model.people.first { $0.fingerprint == phone.fingerprint },
            "everyone on the chain this Mac judges by is listed")
        XCTAssertFalse(theirs.canRevoke)
        let refusal = try XCTUnwrap(theirs.whyNotRevocable)
        XCTAssertEqual(refusal,
                       PeopleAndDevicesModel.revokeNotMine(startedOn: "Amelia"))
        XCTAssertTrue(refusal.contains("Amelia"),
                      "it names the Mac to go to: \(refusal)")
    }

    /// **A device signs its own retirement** (spec §5), so exactly one row
    /// offers it: this Mac's.
    func test_onlyThisMacsOwnRowMayRetire() throws {
        let model = model(registry())
        let devices = model.people.flatMap(\.devices)

        let mine = try XCTUnwrap(devices.first { $0.fingerprint == mac.fingerprint })
        XCTAssertTrue(mine.canRetire)
        XCTAssertNil(mine.whyNotRetirable)

        let theirs = try XCTUnwrap(devices.first { $0.fingerprint == phone.fingerprint })
        XCTAssertFalse(theirs.canRetire)
        XCTAssertEqual(theirs.whyNotRetirable, PeopleAndDevicesModel.retireNotThisDevice)
    }

    // MARK: - The way back, and what retirement means (fix round 1)

    /// **The inverse of a revocation is an admission by the same authority**
    /// (Important 3b), so the row that revoked them offers it — and only that
    /// row: `RegistryAdmission.admit` refuses anybody else's record, and a
    /// button that cannot act is worse than none.
    func test_arevokedRowOffersTheWayBack() throws {
        let model = model(registry(revoked: true))
        let person = try XCTUnwrap(model.people.first { $0.fingerprint == phone.fingerprint })

        XCTAssertTrue(person.canReadmit)
        XCTAssertFalse(person.canRevoke, "there is nothing left to revoke")
        XCTAssertEqual(person.recordedOwnName, "Denver's iPhone",
                       "and a re-admission writes the name the record holds, not a rename")
    }

    /// A person who is not revoked is not offered a way back into a room they
    /// are standing in.
    func test_anadmittedRowOffersNoReadmission() throws {
        let model = model(registry())
        let person = try XCTUnwrap(model.people.first { $0.fingerprint == phone.fingerprint })

        XCTAssertFalse(person.canReadmit)
        XCTAssertTrue(person.canRevoke)
    }

    /// A revoked person under somebody ELSE's root is not this Mac's to let
    /// back in, for the reason they were not this Mac's to revoke.
    func test_arevokedPersonOfAnotherRootIsNotThisMacsToReadmit() throws {
        let registry = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac),
                      deviceRecord(phone, name: "Denver's iPhone")],
            people: [person(otherRoot, label: "Amelia", ownName: "Amelia's MacBook",
                            admittedBy: otherRoot),
                     person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: otherRoot),
                     person(phone, label: "Denver", ownName: "Denver's iPhone",
                            admittedBy: otherRoot, revoked: true)])
        let table = TrustTable.resolve(
            registry: registry, mine: .forAuthor(mac), joinedRoot: nil)

        let model = PeopleAndDevicesModel.make(
            registry: registry, table: table, remembered: [:], requests: [],
            claimants: [], standing: standing(), me: mac.fingerprint)

        let theirs = try XCTUnwrap(model.people.first { $0.fingerprint == phone.fingerprint })
        XCTAssertFalse(theirs.canReadmit)
    }

    /// **The machine that retired is told what retirement means** (Important
    /// 2): its key removed its own future authority and not its ability to
    /// write, so it goes on applying its own lines while every peer sets them
    /// aside — and nothing else on this screen says so.
    func test_thismacsOwnRetiredRowSaysWhatRetirementMeans() throws {
        let retired = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac,
                                   retiredAt: Date(timeIntervalSince1970: 1_757_000_000)),
                      deviceRecord(phone, name: "Denver's iPhone")],
            people: [person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: mac),
                     person(phone, label: "Denver", ownName: "Denver's iPhone",
                            admittedBy: mac)])
        let model = PeopleAndDevicesModel.make(
            registry: retired,
            table: TrustTable.resolve(
                registry: retired, mine: .forAuthor(mac), joinedRoot: nil),
            remembered: [:], requests: [], claimants: [],
            standing: standing(), me: mac.fingerprint)

        let mine = try XCTUnwrap(
            model.people.flatMap(\.devices).first { $0.fingerprint == mac.fingerprint })
        let notice = try XCTUnwrap(mine.retirementNotice)
        XCTAssertTrue(notice.hasPrefix("This Mac retired on "), notice)
        XCTAssertTrue(
            notice.contains(
                "what it writes now stays on this Mac and is set aside everywhere else"),
            notice)
        XCTAssertFalse(mine.canRetire, "and it cannot retire twice")
    }

    /// **A peer's retirement is a fact about a machine the writer is not
    /// sitting at.** The date is on the row; the sentence about what is still
    /// being applied is not, because it would be a claim about somebody else's
    /// desk.
    func test_apeersRetiredRowCarriesTheDateAndNotTheSentence() throws {
        let retired = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac),
                      deviceRecord(phone, name: "Denver's iPhone",
                                   retiredAt: Date(timeIntervalSince1970: 1_757_000_000))],
            people: [person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: mac),
                     person(phone, label: "Denver", ownName: "Denver's iPhone",
                            admittedBy: mac)])
        let model = PeopleAndDevicesModel.make(
            registry: retired,
            table: TrustTable.resolve(
                registry: retired, mine: .forAuthor(mac), joinedRoot: nil),
            remembered: [:], requests: [], claimants: [],
            standing: standing(), me: mac.fingerprint)

        let theirs = try XCTUnwrap(
            model.people.flatMap(\.devices).first { $0.fingerprint == phone.fingerprint })
        XCTAssertNil(theirs.retirementNotice)
        XCTAssertTrue(theirs.detail.contains("retired"), theirs.detail)
    }

    // MARK: - Claimants and merged roots

    /// Somebody claiming a book this device already belongs to another copy of.
    /// Listed, never merged — and the row's one control is *this is also me*,
    /// which is the writer's answer and nobody else's (Task 8).
    func test_aclaimantIsListedWithTheOneQuestionOnlyTheWriterCanAnswer() {
        let model = model(registry(), claimants: [otherRoot.fingerprint])

        XCTAssertEqual(model.claimants.map(\.fingerprint), [otherRoot.fingerprint])
        XCTAssertEqual(model.claimants.first?.code,
                       DeviceCode.short(otherRoot.fingerprint))
        XCTAssertFalse(PeopleAndDevicesModel.mergeHelp.isEmpty)
        XCTAssertTrue(
            PeopleAndDevicesModel.mergeSentence.contains("keeps the book you started"),
            "the sentence says the thing a writer would otherwise assume: "
            + "adopting is not switching")
    }

    /// **Merge is live on a Mac that has a root of its own** — the ordinary
    /// case, and the half a gate must not take away (whole-branch review, I2).
    func test_aclaimantIsMergeableWhenThisMacHasARootOfItsOwn() {
        let model = model(registry(), claimants: [otherRoot.fingerprint])

        let claimant = model.claimants.first
        XCTAssertEqual(claimant?.canMerge, true)
        XCTAssertNil(claimant?.whyNotMergeable,
                     "nil exactly when the verb is offered")
    }

    /// **And refused, in words, on a Mac that joined somebody else's root.**
    ///
    /// A claim is signed by the root record making it, so arm 3 —
    /// `ownRootRecord == nil` — has nothing to sign one with and
    /// `RegistryAdmission.claim` throws `alreadyAdmittedElsewhere`. Drawn live,
    /// the button answered the writer's press with *two chains are merged by
    /// claiming the book, never by admitting into both*, which is the app
    /// telling them to do the thing they just did.
    func test_aclaimantIsNotMergeableWhenThisMacIsOnAnotherRootsChain() {
        let thirdRoot = DeviceIdentity.softwareForTesting()
        // No self-signed record for this Mac: two other roots admitted it, so
        // it JOINED one of them and has no root record of its own.
        let joined = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac)],
            people: [
                person(otherRoot, label: "Amelia", ownName: "Amelia's MacBook",
                       admittedBy: otherRoot),
                person(thirdRoot, label: "Ruth", ownName: "Ruth's MacBook",
                       admittedBy: thirdRoot),
                person(mac, label: "Denver", ownName: "Denver's MacBook",
                       admittedBy: otherRoot),
                person(mac, label: "Denver", ownName: "Denver's MacBook",
                       admittedBy: thirdRoot),
            ])
        let table = TrustTable.resolve(
            registry: joined, mine: .forAuthor(mac), joinedRoot: nil)
        XCTAssertNil(table.ownRootRecord,
                     "the premise: this Mac has no root record of its own")

        let model = PeopleAndDevicesModel.make(
            registry: joined, table: table, remembered: [:], requests: [],
            claimants: [thirdRoot.fingerprint],
            standing: standing(), me: mac.fingerprint)

        let claimant = try! XCTUnwrap(model.claimants.first)
        XCTAssertFalse(claimant.canMerge,
                       "there is no root here to sign a claim with")
        XCTAssertEqual(claimant.whyNotMergeable,
                       PeopleAndDevicesModel.mergeNoRootOfMyOwn)
        XCTAssertFalse(
            PeopleAndDevicesModel.mergeNoRootOfMyOwn.lowercased().contains("merged by"),
            "and the reason does not tell them to merge")
    }

    /// **A claimant this device has adopted is MERGED, not a claimant** (Task
    /// 2's carry). Listing it in both places would ask the writer to answer a
    /// question they have already answered.
    func test_aclaimantThisDeviceAdoptedIsDrawnAsMerged() {
        let claimed = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac)],
            people: [person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: mac),
                     person(otherRoot, label: "Amelia", ownName: "Amelia's MacBook",
                            admittedBy: otherRoot)],
            claims: [ClaimRecord(newRoot: mac.fingerprint,
                                 adopted: [otherRoot.fingerprint],
                                 claimedAt: admitted)])
        let model = model(claimed, claimants: [otherRoot.fingerprint])

        XCTAssertEqual(model.merged.map(\.fingerprint), [otherRoot.fingerprint])
        XCTAssertTrue(model.claimants.isEmpty,
                      "adopted is answered; it is not still asking: \(model.claimants)")
    }

    /// **A person an ADOPTED root admitted is listed** (P3c Task 7, M4). Once
    /// this Mac's root has claimed Amelia's chain the op log applies every line
    /// Sam writes (`TrustTable.verdict` answers `.admitted`), so she is in this
    /// book and the pane must say so — while a person under a root this Mac
    /// never adopted, in the same folder, is still not a row.
    func test_apersonAnAdoptedRootAdmittedIsListedAndAStrangersIsNot() throws {
        let third = DeviceIdentity.softwareForTesting()
        let claimed = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac),
                      deviceRecord(phone, name: "Sam's iPhone"),
                      deviceRecord(stranger, name: "Jo's iPhone")],
            people: [person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: mac),
                     person(otherRoot, label: "Amelia", ownName: "Amelia's MacBook",
                            admittedBy: otherRoot),
                     person(phone, label: "Sam", ownName: "Sam's iPhone",
                            admittedBy: otherRoot),
                     person(third, label: "Lee", ownName: "Lee's MacBook",
                            admittedBy: third),
                     person(stranger, label: "Jo", ownName: "Jo's iPhone",
                            admittedBy: third)],
            claims: [ClaimRecord(newRoot: mac.fingerprint,
                                 adopted: [otherRoot.fingerprint],
                                 claimedAt: admitted)])
        let model = model(claimed)

        let listed = Set(model.people.map(\.fingerprint))
        XCTAssertTrue(listed.contains(phone.fingerprint),
                      "Sam writes in this book, so she is listed: \(listed)")
        XCTAssertFalse(listed.contains(stranger.fingerprint),
                       "a root this Mac never adopted is not this book's row")
        XCTAssertFalse(listed.contains(third.fingerprint))
    }

    // MARK: - What this device remembers

    /// A device this Mac gave a label to, whose record is no longer in the
    /// folder: the memory is the only thing left naming it, and **Forget this
    /// device** is what clears it.
    func test_adeviceRememberedButAbsentCanBeForgotten() {
        let gone = DeviceIdentity.softwareForTesting()
        let model = model(
            registry(),
            remembered: [gone.fingerprint: .init(label: "Amelia",
                                                 ownName: "Amelia's iPhone",
                                                 labelledAt: admitted)])

        XCTAssertEqual(model.absent.map(\.fingerprint), [gone.fingerprint])
        XCTAssertEqual(model.absent.first?.name, "Amelia")
    }

    func test_adeviceRememberedAndStillOnDiskIsNotOfferedForForgetting() {
        let model = model(
            registry(),
            remembered: [phone.fingerprint: .init(label: "Denver",
                                                  ownName: "Denver's iPhone",
                                                  labelledAt: admitted)])

        XCTAssertTrue(model.absent.isEmpty,
                      "its record is right there: \(model.absent)")
    }

    // MARK: - The share sentence

    /// The one sentence that says what this section can and cannot do. Removing
    /// a device stops Maugham applying its writes; it does not take the folder
    /// away from it.
    func test_theShareSentenceIsSaidOnce() {
        XCTAssertTrue(PeopleAndDevicesModel.shareSentence.contains("iCloud share"))
        XCTAssertTrue(PeopleAndDevicesModel.shareSentence.contains("stops Maugham applying"))
    }

    // MARK: - A registry that cannot be read

    /// **RULING-54.** A registry record present and unreadable answers with the
    /// read's own sentence, never with an empty list: empty rows would say
    /// *nobody may write in this book*, which is a trust decision nobody made.
    func test_anUnreadableRegistryShowsItsRefusalRatherThanEmptyRows() {
        let refusal = DeviceStanding.refused(
            mine: .forAuthor(mac),
            error: NSError(domain: "test", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "people/deadbeef.json is present and unreadable"]))
        let model = PeopleAndDevicesModel.make(
            registry: registry(), table: table(registry()), remembered: [:],
            requests: AdmissionDecision.requests(
                pending: [stranger.fingerprint: 4], registry: registry(),
                memory: [:], myRoot: mac.fingerprint),
            claimants: [otherRoot.fingerprint],
            standing: refusal, me: mac.fingerprint)

        XCTAssertEqual(model.refusal, refusal.sentence)
        XCTAssertTrue(model.people.isEmpty)
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertTrue(model.claimants.isEmpty)
        XCTAssertTrue(model.absent.isEmpty)
    }

    // MARK: - No chain at all

    /// B3: a book this device is on no chain of judges nobody, so there is
    /// nobody to list. The standing sentence is what says so.
    func test_abookWithNoChainListsNobody() {
        let empty = Registry()
        let model = PeopleAndDevicesModel.make(
            registry: empty,
            table: TrustTable.resolve(registry: empty, mine: .forAuthor(mac),
                                      joinedRoot: nil),
            remembered: [:], requests: [], claimants: [],
            standing: DeviceStanding(code: DeviceCode.short(mac.fingerprint)),
            me: mac.fingerprint)

        XCTAssertTrue(model.people.isEmpty)
        XCTAssertEqual(model.standing, "Not yet admitted — the Mac will ask")
    }

    // MARK: - Purity

    /// It reads no folder, no clock and no shared memory: the same inputs
    /// answer the same model, twice.
    func test_theModelIsAPureFunctionOfItsInputs() {
        let first = model(registry(), pending: [stranger.fingerprint: 2],
                          claimants: [otherRoot.fingerprint])
        let second = model(registry(), pending: [stranger.fingerprint: 2],
                           claimants: [otherRoot.fingerprint])

        XCTAssertEqual(first, second)
    }
}

/// **What a person's row says about what they may write, and the rows Task 4's
/// three never-offered classes were owed** (signed op log P3b Task 5, spec
/// §7.2).
///
/// Every rule is a value over a registry, a trust table and the held-line union
/// the admission sheet was built from — so what the pane lists, what it offers
/// and what it refuses are all assertable with nothing mounted.
@MainActor
final class PeopleAndDevicesPermitRowTests: XCTestCase {

    private var mac: DeviceIdentity!
    private var phone: DeviceIdentity!
    private var otherRoot: DeviceIdentity!

    override func setUp() async throws {
        mac = .softwareForTesting()
        phone = .softwareForTesting()
        otherRoot = .softwareForTesting()
    }

    private let admitted = Date(timeIntervalSince1970: 1_757_000_000)
    private let made = Date(timeIntervalSince1970: 1_756_000_000)

    private let pieces = [
        PermitControl.Piece(id: "ch1", title: "Chapter 1"),
        PermitControl.Piece(id: "ch4", title: "Chapter 4"),
    ]

    private func device(
        _ identity: DeviceIdentity, name: String, kind: DeviceKind = .phone
    ) -> DeviceRecord {
        DeviceRecord(
            device: identity.fingerprint, name: name, kind: kind,
            actors: [DeviceActor.author.rawValue: identity.fingerprint],
            madeAt: made)
    }

    private func person(
        _ identity: DeviceIdentity, label: String, ownName: String,
        admittedBy: DeviceIdentity, permit: Permit = .author(.book),
        revoked: Bool = false
    ) -> PersonRecord {
        PersonRecord(
            person: identity.fingerprint, label: label, ownName: ownName,
            role: permit.wireRole,
            scope: permit == .author(.book) ? nil : permit.wireScope,
            pieces: permit == .author(.book) ? nil : permit.wirePieces,
            admittedAt: admitted, admittedBy: admittedBy.fingerprint,
            revokedAt: revoked ? admitted.addingTimeInterval(86_400) : nil,
            revokedBy: revoked ? mac.fingerprint : nil)
    }

    private func event(
        _ kind: PermitEvent.Kind, about subject: String, permit: Permit,
        by signer: DeviceIdentity? = nil, id: String = "e-0001"
    ) -> PermitEvent {
        PermitEvent(
            event: id, kind: kind, subject: subject,
            role: permit.wireRole, scope: permit.wireScope,
            pieces: permit.wirePieces, mark: [:], at: admitted,
            by: (signer ?? mac).fingerprint)
    }

    private func registry(
        phonePermit: Permit = .author(.book),
        revoked: Bool = false,
        events: [PermitEvent] = [],
        malformed: [MalformedRecord] = [],
        roots extraRoots: [PersonRecord] = []
    ) -> Registry {
        Registry(
            devices: [
                device(mac, name: "Denver's MacBook", kind: .mac),
                device(phone, name: "Denver's iPhone"),
            ],
            people: [
                person(mac, label: "Denver", ownName: "Denver's MacBook",
                       admittedBy: mac),
                person(phone, label: "Sam", ownName: "Denver's iPhone",
                       admittedBy: mac, permit: phonePermit, revoked: revoked),
            ] + extraRoots,
            events: events,
            malformed: malformed)
    }

    private func model(
        _ registry: Registry,
        held: [String: Int] = [:],
        heldStreams: [String: Set<String>] = [:],
        unsignedStreams: [String] = [],
        restorable: Set<RecordRef> = [],
        me: DeviceIdentity? = nil
    ) -> PeopleAndDevicesModel {
        let identity = me ?? mac!
        let table = TrustTable.resolve(
            registry: registry, mine: .forAuthor(identity), joinedRoot: nil)
        return PeopleAndDevicesModel.make(
            registry: registry, table: table, remembered: [:],
            requests: AdmissionDecision.requests(
                pending: held, streams: heldStreams, registry: registry,
                memory: [:], myRoot: table.myRoot),
            claimants: [], restorable: restorable,
            standing: DeviceStanding(
                code: DeviceCode.short(identity.fingerprint), label: "Denver",
                rootLabel: "Denver", admitted: true,
                isRoot: table.myRoot == identity.fingerprint),
            me: identity.fingerprint,
            held: held, heldStreams: heldStreams,
            unsignedStreams: unsignedStreams, pieces: pieces)
    }

    private func sam(_ model: PeopleAndDevicesModel) throws -> PeopleAndDevicesModel.Person {
        try XCTUnwrap(model.people.first { $0.fingerprint == phone.fingerprint })
    }

    // MARK: - Role and pieces on the row

    /// The row says what they may write, in the words the control uses for it —
    /// so the question the Change… button answers is visible before it is
    /// pressed.
    func test_arowSaysWhatTheyMayWriteAndNamesThePieces() throws {
        let row = try sam(model(registry(phonePermit: .author(.pieces(["ch4"])))))

        XCTAssertEqual(row.rung, .somePieces)
        XCTAssertEqual(row.pieceTitles, ["Chapter 4"])
        XCTAssertEqual(row.permitSentence, "Author of some pieces: Chapter 4")
    }

    /// A piece id this manifest does not carry is drawn as what it is. A
    /// document id is not a thing a writer has ever seen.
    func test_apieceThisMacCannotFindIsNeverDrawnAsItsId() throws {
        let row = try sam(model(registry(phonePermit: .author(.pieces(["ch4", "gone"])))))

        XCTAssertEqual(row.pieceTitles, ["Chapter 4", "a piece this Mac can\u{2019}t find"])
        XCTAssertFalse(row.permitSentence.contains("gone"), row.permitSentence)
    }

    /// An author of no pieces yet is a real state, not an error.
    func test_anAuthorOfNoPiecesYetSaysSo() throws {
        let row = try sam(model(registry(phonePermit: .author(.pieces([])))))

        XCTAssertEqual(row.permitSentence, "Author of some pieces \u{2014} none chosen yet")
    }

    /// A role or scope word a later Maugham wrote is said to be exactly that.
    func test_apermitThisBuildCannotDrawIsSaidToBeUnrecognised() throws {
        var registry = registry()
        registry = Registry(
            devices: registry.devices,
            people: registry.people.map { record -> PersonRecord in
                guard record.person == phone.fingerprint else { return record }
                return PersonRecord(
                    person: record.person, label: record.label,
                    ownName: record.ownName, role: "editor-in-chief",
                    scope: Permit.bookScope, pieces: [],
                    admittedAt: record.admittedAt, admittedBy: record.admittedBy)
            })
        let row = try sam(model(registry))

        XCTAssertNil(row.rung)
        XCTAssertTrue(row.permitSentence.contains("doesn\u{2019}t recognise"),
                      row.permitSentence)
    }

    // MARK: - Who may change it

    /// The root that admitted them, and only them.
    func test_therootThatAdmittedThemMayChangeWhatTheyMayWrite() throws {
        let row = try sam(model(registry()))

        XCTAssertTrue(row.canChangePermit)
        XCTAssertNil(row.whyNotChangeable)
        XCTAssertTrue(row.offersPermitChange)
    }

    /// **The root's own row offers no control at all** — Revoke's exception for
    /// its reason: a root writes the whole book unconditionally and a book must
    /// not end up with no author, so the control could not become live on any
    /// folder, on any day. A disabled button is an offer with a condition on
    /// it; there is no condition here.
    func test_therootsOwnRowDrawsNoChangeControl() throws {
        let model = model(registry())
        let root = try XCTUnwrap(model.people.first { $0.fingerprint == mac.fingerprint })

        XCTAssertFalse(root.offersPermitChange)
        XCTAssertFalse(root.canChangePermit)
        XCTAssertEqual(root.whyNotChangeable, PeopleAndDevicesModel.changeARoot)
    }

    /// **A Mac that did not start this book keeps the button, refused**, naming
    /// the Mac where it can be done — the same destination Rename names, and
    /// the reachable case: the pane lists everybody on the chain this device
    /// judges by, whoever is sitting at it.
    ///
    /// (`alreadyAdmittedElsewhere` is `changePermitOutcome`'s fourth refusal
    /// and is unreachable from this pane, because a person admitted under
    /// another root is not on this chain and so has no row here at all. It is
    /// the verb's guard and stays the verb's.)
    func test_amacThatDidNotStartThisBookIsRefusedAndToldWhere() throws {
        let row = try sam(model(registry(), me: phone))

        XCTAssertTrue(row.offersPermitChange)
        XCTAssertFalse(row.canChangePermit)
        XCTAssertEqual(row.whyNotChangeable,
                       PeopleAndDevicesModel.changeNotMine(startedOn: "Denver"))
    }

    /// A permit no control can draw refuses the control rather than offering to
    /// overwrite a rung the writer was never shown.
    func test_acontrolIsRefusedOverAPermitItCannotDraw() throws {
        let registry = Registry(
            devices: [device(mac, name: "Denver's MacBook", kind: .mac),
                      device(phone, name: "Denver's iPhone")],
            people: [person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: mac),
                     PersonRecord(
                        person: phone.fingerprint, label: "Sam",
                        ownName: "Denver's iPhone", role: "editor-in-chief",
                        scope: Permit.bookScope, pieces: [],
                        admittedAt: admitted, admittedBy: mac.fingerprint)])
        let row = try sam(model(registry))

        XCTAssertFalse(row.canChangePermit)
        XCTAssertEqual(row.whyNotChangeable,
                       PeopleAndDevicesModel.permitThisBuildCannotDraw)
    }

    // MARK: - The record a step behind its history (spec §3.2)

    /// Nothing refuses over this and no load blocks on it, so the row is the
    /// one place it can be said: the screen and the enforcement disagree.
    func test_arecordAStepBehindItsHistorySaysSoAndOffersToCatchUp() throws {
        let row = try sam(model(registry(
            events: [event(.roleChanged, about: phone.fingerprint, permit: .reviewer)])))

        XCTAssertEqual(row.historySays, .reviewer)
        XCTAssertTrue(row.canResign)
        let sentence = try XCTUnwrap(row.behindHistorySentence)
        XCTAssertTrue(sentence.contains("reviewer"), sentence)
        XCTAssertTrue(sentence.contains("a step behind"), sentence)
    }

    /// And a record that agrees says nothing at all — which is every person in
    /// every book written before P3.
    func test_arecordThatAgreesWithItsHistorySaysNothing() throws {
        let row = try sam(model(registry()))

        XCTAssertNil(row.historySays)
        XCTAssertNil(row.behindHistorySentence)
        XCTAssertFalse(row.canResign)
    }

    // MARK: - What a Re-admit would install (Task 4's review, the Critical)

    /// **The permit she held when she was shut out**, read off her timeline —
    /// a revocation installs no entry, so the last thing that did is still the
    /// last word. Before this, Re-admit passed no permit and `DocumentStore
    /// .admit`'s default is the whole book.
    func test_areadmissionProposesThePermitTheyHeldWhenTheyWereRevoked() throws {
        let narrowed = Permit.author(.pieces(["ch4"]))
        let row = try sam(model(registry(
            phonePermit: narrowed, revoked: true,
            events: [event(.scopeChanged, about: phone.fingerprint, permit: narrowed)])))

        XCTAssertTrue(row.canReadmit)
        XCTAssertEqual(row.permitWhenRevoked, narrowed,
                       "never the whole book, which is what a bare admit installed")
    }

    /// A P2-era person with no events re-admits as an author of the whole book,
    /// exactly as before — her timeline says so.
    func test_ap2PersonWithNoEventsStillReadmitsAsTheWholeBook() throws {
        let row = try sam(model(registry(revoked: true)))

        XCTAssertEqual(row.permitWhenRevoked, .author(.book))
    }

    /// **A Re-admit over a permit this build cannot draw is REFUSED** (Task 5's
    /// ruling, built in Task 6) — the same stop Change… makes, one verb over.
    ///
    /// The sheet's control has no rung to start at, so it started at the whole
    /// book after a message. That is a WIDENING chosen by the build that
    /// understands least: an older Maugham putting back a permission it was
    /// never shown. The button is kept and disabled, naming the Maugham where
    /// they can be let back in.
    func test_areadmissionIsRefusedOverAPermitThisBuildCannotDraw() throws {
        let registry = Registry(
            devices: [device(mac, name: "Denver's MacBook", kind: .mac),
                      device(phone, name: "Denver's iPhone")],
            people: [person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: mac),
                     PersonRecord(
                        person: phone.fingerprint, label: "Sam",
                        ownName: "Denver's iPhone", role: "editor-in-chief",
                        scope: Permit.bookScope, pieces: [],
                        admittedAt: admitted, admittedBy: mac.fingerprint,
                        revokedAt: admitted.addingTimeInterval(86_400),
                        revokedBy: mac.fingerprint)],
            events: [event(
                .roleChanged, about: phone.fingerprint,
                permit: Permit.parse(role: "editor-in-chief",
                                     scope: Permit.bookScope, pieces: []))])
        let row = try sam(model(registry))

        XCTAssertNil(
            PermitControl.choice(displaying: row.permitWhenRevoked),
            "the premise: no control can draw what she held")
        XCTAssertEqual(
            row.whyNotReadmittable,
            PeopleAndDevicesModel.permitThisBuildCannotReinstall)
        XCTAssertTrue(
            row.canReadmit,
            "the button is kept and disabled, like Rename's and Change's")
        XCTAssertFalse(
            row.whyNotReadmittable?.contains("whole book") ?? true,
            "and it never offers the fallback that was the defect")
    }

    /// The other direction: an ordinary revoked person is offered Re-admit with
    /// nothing said against it.
    func test_anordinaryRevokedPersonIsReadmittableWithNoRefusal() throws {
        let row = try sam(model(registry(
            phonePermit: .author(.pieces(["ch4"])), revoked: true,
            events: [event(.scopeChanged, about: phone.fingerprint,
                           permit: .author(.pieces(["ch4"])))])))

        XCTAssertTrue(row.canReadmit)
        XCTAssertNil(row.whyNotReadmittable)
    }

    // MARK: - Held keys that are nobody to ask about

    /// A non-author actor key is silent in the sheet by design; this is the
    /// line that says why, and it names the actor in the app's own vocabulary.
    func test_anonAuthorActorKeyGetsALineRatherThanASheet() throws {
        let key = "ffff0000ffff0000ffff0000ffff0000"
        // The shape `DeviceSlug.make` produces for a non-author actor: the
        // actor word, a hyphen, and a PREFIX of the key's hex (truncated at 24
        // characters, so 13–16 of it rather than always 16).
        let slug = "assistant-\(key.prefix(13))"
        let model = model(
            registry(), held: [key: 3], heldStreams: [key: [slug]])

        XCTAssertTrue(model.pending.isEmpty, "never a sheet")
        let row = try XCTUnwrap(model.waiting.first)
        XCTAssertEqual(row.fingerprint, key)
        XCTAssertEqual(row.heldLines, 3)
        XCTAssertTrue(row.sentence.contains("The assistant"), row.sentence)
        XCTAssertFalse(row.sentence.lowercased().contains("claude"),
                       "the AI actor is never given a product name: \(row.sentence)")
    }

    /// A stranger with an author key keeps her sheet and gets no waiting row —
    /// the two lists are the same decision, asked once.
    func test_astrangerWithAnAuthorKeyIsStillASheetAndNotAWaitingRow() throws {
        let stranger = DeviceIdentity.softwareForTesting()
        let model = model(registry(), held: [stranger.fingerprint: 2])

        XCTAssertEqual(model.pending.map(\.fingerprint), [stranger.fingerprint])
        XCTAssertTrue(model.waiting.isEmpty)
    }

    /// A key two device records claim is nobody's for good, and naming an owner
    /// would decide the thing the dispute rule refuses to decide.
    func test_acontestedKeyGetsItsOwnLine() throws {
        let contested = "aaaa1111aaaa1111aaaa1111aaaa1111"
        let registry = Registry(
            devices: [
                DeviceRecord(device: mac.fingerprint, name: "Denver's MacBook",
                             kind: .mac,
                             actors: [DeviceActor.author.rawValue: mac.fingerprint,
                                      DeviceActor.assistant.rawValue: contested],
                             madeAt: made),
                DeviceRecord(device: phone.fingerprint, name: "Denver's iPhone",
                             kind: .phone,
                             actors: [DeviceActor.author.rawValue: phone.fingerprint,
                                      DeviceActor.assistant.rawValue: contested],
                             madeAt: made),
            ],
            people: [person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: mac)])
        let model = model(registry, held: [contested: 4])

        XCTAssertFalse(model.pending.map(\.fingerprint).contains(contested),
                       "a contested key is never a pending row")
        // F10: the phone's record has no person record in this fixture, so the
        // record alone is now a pending row of its own.
        XCTAssertTrue(model.pending.map(\.fingerprint).contains(phone.fingerprint))
        let row = try XCTUnwrap(model.waiting.first)
        XCTAssertEqual(row.sentence, PeopleAndDevicesModel.contestedKey)
    }

    // MARK: - Streams nothing signs (#8)

    /// **Before any narrowing**, the row says what is true now and what
    /// narrowing WILL do — which is the half the writer must read before they
    /// make the first reviewer, because that day is a cliff and not a slope.
    func test_anunsignedStreamSaysWhatNarrowingWillDoBeforeThereIsAReviewer() throws {
        let model = model(registry(), unsignedStreams: ["ghostmac"])

        XCTAssertFalse(model.alreadyNarrowed)
        let row = try XCTUnwrap(model.unsigned.first)
        XCTAssertEqual(row.stream, "ghostmac")
        XCTAssertTrue(row.sentence.contains("Nothing this book holds says who signs"),
                      row.sentence)
        XCTAssertTrue(
            PeopleAndDevicesModel.UnsignedStream.beforeNarrowing
                .contains("waits on the other Macs"),
            "the cliff, stated before it")
        XCTAssertTrue(
            PeopleAndDevicesModel.UnsignedStream.beforeNarrowing
                .contains("nothing it has already written changes"))
    }

    /// **The sentence is true in both of its two cases** (Task 2's review, M2):
    /// a Mac with no Secure Enclave, and a Mac that signs perfectly well whose
    /// first seal has not synced yet. This Mac cannot tell them apart and never
    /// claims to.
    func test_theunsignedSentenceNeverClaimsAnythingAboutThatMacsHardware() {
        let row = PeopleAndDevicesModel.UnsignedStream(stream: "ghostmac")

        for sentence in [row.sentence,
                         PeopleAndDevicesModel.UnsignedStream.beforeNarrowing,
                         PeopleAndDevicesModel.UnsignedStream.afterNarrowing] {
            XCTAssertFalse(sentence.localizedCaseInsensitiveContains("enclave"), sentence)
            XCTAssertFalse(sentence.localizedCaseInsensitiveContains("can\u{2019}t sign"),
                           sentence)
            XCTAssertFalse(sentence.localizedCaseInsensitiveContains("no key"), sentence)
        }
    }

    /// Once the book has been narrowed the tense changes and nothing else does.
    func test_anunsignedStreamInANarrowedBookSpeaksInThePastTense() throws {
        let narrowed = registry(
            phonePermit: .reviewer,
            events: [event(.roleChanged, about: phone.fingerprint, permit: .reviewer)])
        let model = model(narrowed, unsignedStreams: ["ghostmac"])

        XCTAssertTrue(model.alreadyNarrowed)
        XCTAssertTrue(
            PeopleAndDevicesModel.UnsignedStream.afterNarrowing
                .contains("Nothing it wrote before then changed."))
    }

    // MARK: - C2, and F4

    /// **C2: a nameless device never shows its code as its own name.** A device
    /// that reached the sheet with no record of its own proposes no name, and
    /// the code goes in its place — so the row read *Denver (4FD2)*, the
    /// writer's label beside a checksum presented as a machine name.
    func test_anamelessDeviceNeverShowsItsCodeAsItsOwnName() throws {
        let code = DeviceCode.short(phone.fingerprint)
        let registry = Registry(
            devices: [device(mac, name: "Denver's MacBook", kind: .mac)],
            people: [person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: mac),
                     PersonRecord(person: phone.fingerprint, label: "Sam",
                                  ownName: code, admittedAt: admitted,
                                  admittedBy: mac.fingerprint)])
        let row = try sam(model(registry))

        XCTAssertNil(row.ownName)
        XCTAssertEqual(row.title, "Sam")
    }

    /// **F4**: this device's own record, unreadable, with no bytes to restore.
    /// Restore's case with nothing to restore, and until now no way out at all.
    func test_thismacsOwnUnrestorableRecordOffersToBeWrittenAgain() throws {
        let ref = RecordRef(directory: .devices, fingerprint: mac.fingerprint)
        let model = model(registry(malformed: [MalformedRecord(
            url: URL(fileURLWithPath:
                "/Book/.maugham/devices/\(mac.fingerprint).json"),
            reason: .signatureDoesNotVerify)]))

        let row = try XCTUnwrap(model.unverifiable.first { $0.ref == ref })
        XCTAssertTrue(row.canWriteAgain)
        XCTAssertFalse(row.canRestore)
        XCTAssertNil(row.whoRepairsIt, "there is a press; it is not a dead end")
    }

    /// **Never for another device's record.** A device record is signed by the
    /// machine it describes, so the row names the Mac that must open the book.
    func test_anotherDevicesUnverifiableRecordIsNeverOfferedAndNamesWhoCanFixIt() throws {
        let ref = RecordRef(directory: .devices, fingerprint: phone.fingerprint)
        let model = model(registry(malformed: [MalformedRecord(
            url: URL(fileURLWithPath:
                "/Book/.maugham/devices/\(phone.fingerprint).json"),
            reason: .signatureDoesNotVerify)]))

        let row = try XCTUnwrap(model.unverifiable.first { $0.ref == ref })
        XCTAssertFalse(row.canWriteAgain)
        XCTAssertNotNil(row.whoRepairsIt, "never a dead end")
    }

    /// **Never where Restore can do it.** The two are alternatives, and the one
    /// that puts back bytes this Mac read is always the better answer.
    func test_arecordThisMacCanRestoreIsNeverOfferedANewOne() throws {
        let ref = RecordRef(directory: .devices, fingerprint: mac.fingerprint)
        let model = model(
            registry(malformed: [MalformedRecord(
                url: URL(fileURLWithPath:
                    "/Book/.maugham/devices/\(mac.fingerprint).json"),
                reason: .signatureDoesNotVerify)]),
            restorable: [ref])

        let row = try XCTUnwrap(model.unverifiable.first { $0.ref == ref })
        XCTAssertTrue(row.canRestore)
        XCTAssertFalse(row.canWriteAgain)
    }

    /// **The person arm is narrower.** Re-writing a person record self-signed
    /// makes this Mac a root; where the book still has a verified root, that
    /// would be a second root made out of a damaged file, so the row names that
    /// Mac instead.
    func test_adamagedPersonRecordInSomebodyElsesBookNamesTheMacThatDecides() throws {
        let ref = RecordRef(directory: .people, fingerprint: mac.fingerprint)
        let registry = Registry(
            devices: [device(mac, name: "Denver's MacBook", kind: .mac),
                      device(otherRoot, name: "Amelia's iMac", kind: .mac)],
            people: [person(otherRoot, label: "Amelia", ownName: "Amelia's iMac",
                            admittedBy: otherRoot)],
            malformed: [MalformedRecord(
                url: URL(fileURLWithPath:
                    "/Book/.maugham/people/\(mac.fingerprint).json"),
                reason: .signatureDoesNotVerify)])
        let model = model(registry)

        let row = try XCTUnwrap(model.unverifiable.first { $0.ref == ref })
        XCTAssertFalse(row.canWriteAgain)
        XCTAssertTrue(row.whoRepairsIt?.contains("Amelia") == true,
                      "\(String(describing: row.whoRepairsIt))")
    }

    /// And the sole root record tampered with — audit F4 itself — IS offered,
    /// because there is nobody else to ask.
    func test_thesoleRootRecordIsOfferedToTheMacItNames() throws {
        let ref = RecordRef(directory: .people, fingerprint: mac.fingerprint)
        let registry = Registry(
            devices: [device(mac, name: "Denver's MacBook", kind: .mac)],
            people: [],
            malformed: [MalformedRecord(
                url: URL(fileURLWithPath:
                    "/Book/.maugham/people/\(mac.fingerprint).json"),
                reason: .signatureDoesNotVerify)])
        let model = model(registry)

        let row = try XCTUnwrap(model.unverifiable.first { $0.ref == ref })
        XCTAssertTrue(row.canWriteAgain)
    }
}

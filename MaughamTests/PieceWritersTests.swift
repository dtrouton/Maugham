import XCTest
@testable import Maugham
@testable import MaughamCore

/// **Whose piece is whose** (signed op log P3b Task 9, spec §7.5).
///
/// A book somebody writes alone says nothing about authorship anywhere — the
/// whole surface is absent, which is the direction that matters: a field
/// reading *Written by Denver* on every chapter of a book with one writer in
/// it is noise that trains the eye past the one case it exists for.
///
/// The one case is a book where somebody's permit names PIECES. `PieceWriters`
/// is the whole decision, as a value over a verified registry and its trust
/// table, so both surfaces that draw it — the Inspector's row and the altitude
/// table's column — read one answer and cannot disagree.
///
/// **It asks the permit layer and nothing else.** Who authors a piece is
/// `Permit.authors(.piece(id))`; which pieces a permit NAMES is
/// `PermitControl.pieces(displaying:)`, the accessor the People & Devices row
/// already draws from. No rung is compared here (tripwire 47) and no
/// `PersonRecord.role`/`.scope`/`.pieces` is read (tripwire 43) — the permit in
/// force is the TIMELINE's, because a record is re-signed in place and forgets
/// its own past.
@MainActor
final class PieceWritersTests: XCTestCase {

    private var mac: DeviceIdentity!
    private var phone: DeviceIdentity!
    private var laptop: DeviceIdentity!
    private var otherRoot: DeviceIdentity!

    override func setUp() async throws {
        mac = .softwareForTesting()
        phone = .softwareForTesting()
        laptop = .softwareForTesting()
        otherRoot = .softwareForTesting()
    }

    // MARK: - Fixture

    private let admitted = Date(timeIntervalSince1970: 1_757_000_000)
    private let made = Date(timeIntervalSince1970: 1_756_000_000)

    private let pieces = [
        PermitControl.Piece(id: "ch1", title: "Chapter 1"),
        PermitControl.Piece(id: "ch2", title: "Chapter 2"),
        PermitControl.Piece(id: "ch3", title: "Chapter 3"),
    ]

    private func device(
        _ identity: DeviceIdentity, name: String, kind: DeviceKind = .phone
    ) -> DeviceRecord {
        DeviceRecord(
            device: identity.fingerprint, name: name, kind: kind,
            actors: [DeviceActor.author.rawValue: identity.fingerprint],
            madeAt: made)
    }

    /// A person record. `permit` fills the record's own three fields — the
    /// current-state convenience — which is exactly what this decision must
    /// NOT read where a timeline says otherwise.
    private func person(
        _ identity: DeviceIdentity, label: String,
        admittedBy: DeviceIdentity, permit: Permit = .author(.book),
        revoked: Bool = false
    ) -> PersonRecord {
        PersonRecord(
            person: identity.fingerprint, label: label,
            ownName: "\(label)\u{2019}s machine",
            role: permit.wireRole,
            scope: permit == .author(.book) ? nil : permit.wireScope,
            pieces: permit == .author(.book) ? nil : permit.wirePieces,
            admittedAt: admitted, admittedBy: admittedBy.fingerprint,
            revokedAt: revoked ? admitted.addingTimeInterval(86_400) : nil,
            revokedBy: revoked ? mac.fingerprint : nil)
    }

    private func event(
        _ kind: PermitEvent.Kind, about subject: String, permit: Permit,
        id: String = "e-0001"
    ) -> PermitEvent {
        PermitEvent(
            event: id, kind: kind, subject: subject,
            role: permit.wireRole, scope: permit.wireScope,
            pieces: permit.wirePieces, mark: [:], at: admitted,
            by: mac.fingerprint)
    }

    /// **Somebody admitted with a permit, the way P3b's own verbs admit
    /// them** — the record's three fields AND the event that installed it.
    ///
    /// Both halves matter and they are not interchangeable: the record is the
    /// current-state convenience, and what every reader in the book judges by
    /// is the EVENT, through `PermitTimeline`. `RegistryAdmission.admit` and
    /// `changePermit` write both, so a fixture that wrote only one would be
    /// describing a state the app cannot produce — and the two tests below
    /// that deliberately DO disagree are the crash window, named as such.
    private func member(
        _ identity: DeviceIdentity, label: String, permit: Permit,
        revoked: Bool = false, eventId: String
    ) -> (PersonRecord, PermitEvent) {
        (person(identity, label: label, admittedBy: mac, permit: permit,
                revoked: revoked),
         event(.admitted, about: identity.fingerprint, permit: permit,
               id: eventId))
    }

    /// This Mac is the root; `others` are everybody it has admitted.
    private func registry(
        _ others: [(PersonRecord, PermitEvent)] = [],
        loose: [PersonRecord] = [], events: [PermitEvent] = []
    ) -> Registry {
        Registry(
            devices: [device(mac, name: "Denver\u{2019}s MacBook", kind: .mac)],
            people: [person(mac, label: "Denver", admittedBy: mac)]
                + others.map(\.0) + loose,
            events: others.map(\.1) + events)
    }

    private func writers(
        _ registry: Registry, me: DeviceIdentity? = nil
    ) -> PieceWriters {
        let identity = me ?? mac!
        let table = TrustTable.resolve(
            registry: registry, mine: .forAuthor(identity), joinedRoot: nil)
        return PieceWriters.resolve(
            registry: registry, table: table, pieces: pieces)
    }

    // MARK: - A book with one writer in it says nothing

    /// The whole surface's premise. Nobody's permit names a piece, so there is
    /// nothing to draw and the two surfaces draw nothing.
    func test_aBookWithOneWriterInItNamesNobody() {
        let alone = writers(registry())

        XCTAssertTrue(alone.isEmpty)
        XCTAssertNil(alone.sentence(for: "ch1"))
        XCTAssertNil(alone.sentence(for: "ch2"))
    }

    /// **And a book of whole-book co-authors says nothing either** — the
    /// decision this task had to make, and the direction it went. Three people
    /// who may each write the whole of it have nothing to tell each other about
    /// which chapter is whose, and a column repeating the same three names down
    /// every row would be the one-author case's noise multiplied.
    func test_aBookOfWholeBookCoAuthorsNamesNobodyEither() {
        let both = writers(registry([
            member(phone, label: "Sam", permit: .author(.book), eventId: "e-1"),
            member(laptop, label: "Ada", permit: .author(.book), eventId: "e-2"),
        ]))

        XCTAssertTrue(both.isEmpty)
        XCTAssertNil(both.sentence(for: "ch1"))
    }

    /// A reviewer authors nothing anywhere, so she is named nowhere — the
    /// other permit whose scope names no piece.
    func test_areviewerIsNamedOnNoPiece() {
        let reviewed = writers(registry([
            member(phone, label: "Sam", permit: .reviewer, eventId: "e-1"),
        ]))

        XCTAssertTrue(reviewed.isEmpty)
    }

    // MARK: - A scoped author is named on her own pieces

    func test_ascopedAuthorIsNamedOnHerOwnPieceAndNowhereElse() {
        let scoped = writers(registry([
            member(phone, label: "Sam", permit: .author(.pieces(["ch2"])),
                   eventId: "e-1"),
        ]))

        XCTAssertFalse(scoped.isEmpty)
        XCTAssertEqual(scoped.sentence(for: "ch2"), "Sam")
        XCTAssertNil(scoped.sentence(for: "ch1"))
        XCTAssertNil(scoped.sentence(for: "ch3"))
    }

    /// Two people on one piece read as a sentence, not a list of two answers.
    func test_twoWritersOfOnePieceReadAsOneSentence() {
        let shared = writers(registry([
            member(phone, label: "Sam", permit: .author(.pieces(["ch2"])),
                   eventId: "e-1"),
            member(laptop, label: "Ada", permit: .author(.pieces(["ch2", "ch3"])),
                   eventId: "e-2"),
        ]))

        XCTAssertEqual(shared.sentence(for: "ch2"), "Ada and Sam")
        XCTAssertEqual(shared.sentence(for: "ch3"), "Ada")
        XCTAssertNil(shared.sentence(for: "ch1"))
    }

    func test_threeWritersReadAsAList() {
        let crowd = writers(registry([
            member(phone, label: "Sam", permit: .author(.pieces(["ch1"])),
                   eventId: "e-1"),
            member(laptop, label: "Ada", permit: .author(.pieces(["ch1"])),
                   eventId: "e-2"),
            member(otherRoot, label: "Jo", permit: .author(.pieces(["ch1"])),
                   eventId: "e-3"),
        ]))

        XCTAssertEqual(crowd.sentence(for: "ch1"), "Ada, Jo and Sam")
    }

    /// **One label, two machines, one name.** P2b's admission merges a
    /// writer's Mac and phone under one label, so a book where Sam works on
    /// both must not read *Sam and Sam*.
    func test_twoRecordsUnderOneLabelAreOneName() {
        let twoMachines = writers(registry([
            member(phone, label: "Sam", permit: .author(.pieces(["ch2"])),
                   eventId: "e-1"),
            member(laptop, label: "Sam", permit: .author(.pieces(["ch2"])),
                   eventId: "e-2"),
        ]))

        XCTAssertEqual(twoMachines.writers(of: "ch2"), ["Sam"])
        XCTAssertEqual(twoMachines.sentence(for: "ch2"), "Sam")
    }

    /// A scope naming a piece this book does not hold names nothing. A
    /// document id is not a row, and a deleted chapter is not a row either.
    func test_apieceThisBookDoesNotHoldIsNamedNowhere() {
        let stale = writers(registry([
            member(phone, label: "Sam", permit: .author(.pieces(["gone"])),
                   eventId: "e-1"),
        ]))

        XCTAssertTrue(stale.isEmpty)
        XCTAssertNil(stale.sentence(for: "gone"))
    }

    // MARK: - The permit in force is the timeline's (tripwire 43)

    /// The record still says author of the whole book; an event has narrowed
    /// her since. The row follows the event.
    func test_therecordsOwnFieldsNeverDecide_narrowedByAnEvent() {
        let narrowed = writers(registry(
            loose: [person(phone, label: "Sam", admittedBy: mac)],
            events: [event(.admitted, about: phone.fingerprint,
                           permit: .author(.book), id: "e-1"),
                     event(.scopeChanged, about: phone.fingerprint,
                           permit: .author(.pieces(["ch3"])), id: "e-2")]))

        XCTAssertEqual(narrowed.sentence(for: "ch3"), "Sam")
        XCTAssertNil(narrowed.sentence(for: "ch1"))
    }

    /// And the other direction, which is the one that would put a name on
    /// every row of a book that has none: the record's fields name a piece, an
    /// event has since widened her back to the whole book, and she is named
    /// nowhere.
    func test_therecordsOwnFieldsNeverDecide_widenedByAnEvent() {
        let widened = writers(registry(
            loose: [person(phone, label: "Sam", admittedBy: mac,
                           permit: .author(.pieces(["ch2"])))],
            events: [event(.admitted, about: phone.fingerprint,
                           permit: .author(.pieces(["ch2"])), id: "e-1"),
                     event(.roleChanged, about: phone.fingerprint,
                           permit: .author(.book), id: "e-2")]))

        XCTAssertTrue(widened.isEmpty)
        XCTAssertNil(widened.sentence(for: "ch2"))
    }

    // MARK: - Who is in this book at all

    /// A revoked person writes nothing anywhere, so she is named nowhere. The
    /// row answers *who writes this piece*; what she already wrote is
    /// History's, and stays in the manuscript.
    func test_arevokedPersonIsNamedOnNoPiece() {
        let gone = writers(registry([
            member(phone, label: "Sam", permit: .author(.pieces(["ch2"])),
                   revoked: true, eventId: "e-1"),
        ]))

        XCTAssertTrue(gone.isEmpty)
        XCTAssertNil(gone.sentence(for: "ch2"))
    }

    /// Somebody under ANOTHER root is that root's business. This device judges
    /// by one chain and draws that one — the same rule the People & Devices
    /// pane lists its rows by, asked once rather than answered twice.
    ///
    /// Her permit is installed by an EVENT, not only written into her record:
    /// without that the timeline would answer author-of-the-whole-book about
    /// her and the scope guard would drop her for an unrelated reason, so the
    /// chain restriction would be the only thing this test was NOT pinning
    /// (measured — the disable experiment stayed green until the event was
    /// added).
    func test_apersonUnderAnotherRootIsNamedNowhereHere() {
        let foreign = Registry(
            devices: [
                device(mac, name: "Denver\u{2019}s MacBook", kind: .mac),
                device(otherRoot, name: "Another Mac", kind: .mac),
            ],
            people: [
                person(mac, label: "Denver", admittedBy: mac),
                person(otherRoot, label: "Kim", admittedBy: otherRoot),
                person(phone, label: "Sam", admittedBy: otherRoot,
                       permit: .author(.pieces(["ch2"]))),
            ],
            events: [event(.admitted, about: phone.fingerprint,
                           permit: .author(.pieces(["ch2"])), id: "e-1")])

        XCTAssertTrue(writers(foreign).isEmpty)
    }

    /// **A person an ADOPTED root admitted is named here** (P3c Task 7, M4) —
    /// the other direction of the test above. Once this Mac's root has claimed
    /// Kim's chain, every line Sam writes is applied here (`TrustTable
    /// .verdict` answers `.admitted`), so she is in this book and her piece
    /// carries her name — and the root's yields, which read this answer, yield
    /// to her. A person under a root this Mac did NOT adopt stays nobody's
    /// here, in the same folder.
    func test_apersonAnAdoptedRootAdmittedIsNamedOnHerPiece() {
        let third = DeviceIdentity.softwareForTesting()
        let stranger = DeviceIdentity.softwareForTesting()
        let adopted = Registry(
            devices: [
                device(mac, name: "Denver\u{2019}s MacBook", kind: .mac),
                device(otherRoot, name: "Another Mac", kind: .mac),
                device(third, name: "A third Mac", kind: .mac),
            ],
            people: [
                person(mac, label: "Denver", admittedBy: mac),
                person(otherRoot, label: "Kim", admittedBy: otherRoot),
                person(phone, label: "Sam", admittedBy: otherRoot,
                       permit: .author(.pieces(["ch2"]))),
                person(third, label: "Lee", admittedBy: third),
                person(stranger, label: "Jo", admittedBy: third,
                       permit: .author(.pieces(["ch3"]))),
            ],
            claims: [ClaimRecord(newRoot: mac.fingerprint,
                                 adopted: [otherRoot.fingerprint],
                                 claimedAt: admitted)],
            events: [
                event(.admitted, about: phone.fingerprint,
                      permit: .author(.pieces(["ch2"])), id: "e-1"),
                event(.admitted, about: stranger.fingerprint,
                      permit: .author(.pieces(["ch3"])), id: "e-2"),
            ])

        let named = writers(adopted)
        XCTAssertEqual(named.sentence(for: "ch2"), "Sam",
                       "an adopted root's member writes in this book")
        XCTAssertNil(named.sentence(for: "ch3"),
                     "a root this Mac never adopted is still nobody's here")
    }

    /// A keyless Mac — one that has never signed anything here — resolves to a
    /// table with no root of its own. It draws nothing rather than guessing.
    func test_amacThatJudgesByNoRootNamesNobody() {
        let keyless = PieceWriters.resolve(
            registry: Registry(),
            table: TrustResolution.keyless(mine: .forAuthor(mac)),
            pieces: pieces)

        XCTAssertTrue(keyless.isEmpty)
    }
}
